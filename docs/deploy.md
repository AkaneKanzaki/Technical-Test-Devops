# Part II — Deploy

## Deliverables

- All commands actually used (run / cp / signal), below.
- `curl` output before and after the binary swap.
- 3–5 sentence explanation of which approach was chosen and why.

Raw transcripts backing this document:

| File | Contents |
|------|----------|
| `screenshots/part2-hotswap.log` | before/after state, container and image identity, binary SHA |
| `screenshots/part2-downtime.log` | request loop running across a swap — 0 failures |

## Run the image

```
$ ./scripts/run.sh devops-hello-demo 1.0.0 8890
started devops-hello-demo on host port 8890 (image devops-hello:1.0.0)
```

The script expands to:

```
docker run -d \
    --name devops-hello-demo \
    -p 8890:8080 \
    --restart unless-stopped \
    devops-hello:1.0.0
```

`--restart unless-stopped` satisfies the "restart automatically on crash" requirement.

> **Port note:** the app is published on **8888** for the Jenkins production container and
> **8890** for this standalone demo, because Jenkins itself owns 8080 on this machine.
> The container's internal port is always 8080 (`EXPOSE 8080`).

```
$ curl -s http://localhost:8890/
Hello, DevOps! version=1.0.0
$ curl -s http://localhost:8890/health
ok
$ curl -s http://localhost:8890/version
1.0.0
```

## Hot-swap: commands

Scenario: a small bug fix is released as `1.0.2`. The running container must start serving the
new binary without rebuilding the image and without removing the container.

```
$ ./scripts/build.sh 1.0.2 .bin/hello-v2
built .bin/hello-v2 (version=1.0.2)

$ docker cp .bin/hello-v2 devops-hello-demo:/usr/local/bin/hello

$ docker exec devops-hello-demo sh -c 'kill -HUP 1'
   # tini forwards SIGHUP to entrypoint.sh, whose handler stops the running
   # hello child. The supervisor loop then re-spawns /usr/local/bin/hello,
   # which is now the 1.0.2 binary. The supervisor itself never exits, so
   # PID 1 stays alive and Docker never restarts the container.
```

A polling loop in `scripts/swap-binary.sh` waits for `/version` to flip:

```
$ ./scripts/swap-binary.sh devops-hello-demo 1.0.1 .bin/hello-v2 8890
built .bin/hello-v2 (version=1.0.1)
waiting for version=1.0.1 on http://localhost:8890 ... ok in 1883 ms
curl /        -> Hello, DevOps! version=1.0.1
curl /version -> 1.0.1
```

## curl output before vs after

```
$ curl -s http://localhost:8890/        # before
Hello, DevOps! version=1.0.0

$ curl -s http://localhost:8890/version # before
1.0.0

$ curl -s http://localhost:8890/        # after
Hello, DevOps! version=1.0.1

$ curl -s http://localhost:8890/version # after
1.0.1
```

## Proof the image was not rebuilt, the container was not restarted, and it was not removed

Seven independent signals, captured in `screenshots/part2-hotswap.log`:

| Signal | Before | After | Meaning |
|---|---|---|---|
| container ID | `09de2de6f810…` | `09de2de6f810…` | container object never removed or recreated |
| `Created` | `09:51:13.95028319Z` | `09:51:13.95028319Z` | never recreated from scratch |
| `State.StartedAt` | `09:51:14.019586639Z` | `09:51:14.019586639Z` | **PID 1 never exited** — no container restart |
| `RestartCount` | `0` | `0` | Docker's restart counter never incremented |
| image ID | `sha256:7795b72e…` | `sha256:7795b72e…` | no `docker build` was run |
| `entrypoint.sh` PID | `7` | `7` | the supervisor loop kept running throughout |
| binary SHA | `bc1d01d2…` → | `bc1d01d2…` (new) | the file inside was replaced |

The process tree shows the swap is genuinely in-place — PID 1 and the supervisor keep
their PIDs, and only the child is replaced:

```
before                          after
PID   PPID  COMMAND             PID   PPID  COMMAND
    1     0 tini                  1     0 tini          <- unchanged
    7     1 entrypoint.sh         7     1 entrypoint.sh <- unchanged
    8     7 hello                31     7 hello         <- replaced
```

```
$ sha256sum .bin/hello-v2
bc1d01d264491b3c9ae11f35210ba0296882e3ef956c9544a2fdbb2c6dc016f5  .bin/hello-v2

$ docker exec devops-hello-demo sh -c "sha256sum /usr/local/bin/hello"
bc1d01d264491b3c9ae11f35210ba0296882e3ef956c9544a2fdbb2c6dc016f5  /usr/local/bin/hello
```

The new binary inside the container is byte-identical to the one built on the host.

### How the supervisor achieves a restart-free swap

The first version of `entrypoint.sh` exited on SIGHUP, which meant PID 1 exited too and
Docker's `--restart` policy had to bring the container back. That worked, but it moved
`State.StartedAt` forward and cost ~1.2 s of worst-case stall.

The current version never exits on SIGHUP. The handler only signals the running child, and
the main loop re-spawns the binary on its next iteration:

```sh
on_hup() {
    SWAP=1
    kill -TERM "$CHILD" 2>/dev/null || true    # no exit here
}
trap on_hup HUP
...
while true; do
    "$BIN" & CHILD=$!
    wait "$CHILD" || rc=$?
    [ "$SWAP" = "1" ] && { SWAP=0; continue; }  # respawn immediately
    sleep 1
done
```

`TERM`/`INT` still exit, so `docker stop` shuts the container down normally. Docker never
sees PID 1 die, so `RestartCount` stays at 0 and `StartedAt` never moves.

## Measured impact on live traffic

`scripts/swap-measure.sh` hammers `/version` in a tight loop, fires a swap partway through,
and reports the result. From `screenshots/part2-downtime.log`:

```
$ ./scripts/swap-measure.sh devops-hello-demo 1.0.2 8890

baseline version: 1.0.1
waiting for version=1.0.2 on http://localhost:8890 ... ok in 2295 ms

--- hot-swap impact ---
requests observed      : 30
responses ok           : 30
responses failed       : 0
  served old version   : 21
  served new version   : 9
version flipped at     : request #22
longest gap between    : 757 ms  (worst-case user-visible stall)
total window           : 19137 ms
verdict                : no request failed during the swap

container restarts during the measurement:
  RestartCount=0  StartedAt=2026-09-28T09:51:14.019586639Z
```

**Not one request failed**, and the container's restart counter stayed at zero. The worst
case a client could observe is a ~0.76 s stall while the supervisor respawns the child —
comfortably inside the brief's "at most a few seconds".

For comparison, the earlier exit-on-SIGHUP design measured a 1235 ms worst-case stall and
did increment `StartedAt`. Removing the container restart cut the worst-case stall by
roughly 40% and eliminated the restart entirely.

> The `ok in 2295 ms` figure reported by `swap-binary.sh` is wall-clock from just before
> `docker exec` to the first new-version response. It includes Docker Desktop's overhead for
> starting a process inside the container, so it overstates the actual service gap — the
> load test's 757 ms is the honest downtime number.

## Approach choice and why

I picked **`docker cp` + in-container supervisor signal** (option A from the brief). It maps
directly to "swap the binary running inside the container, without a full `docker build` and
without removing the currently running container" — and the evidence shows something stronger:
the container is not even restarted. Container ID, `Created`, `StartedAt`, `RestartCount` and
image ID are all unchanged; only `/usr/local/bin/hello` is overwritten and the supervisor
re-spawns it. The new binary is serving within ~2 s, with zero failed requests in the measured
window and a worst-case client stall of 757 ms. The volume-mount alternative (option B) would
also work and is closer to traditional hot-deploy patterns, but it forces the operator to keep
a host directory synchronized with the image and complicates the `Dockerfile` (the binary
would have to be excluded from a later copy layer). `docker cp` keeps the image self-contained
and the swap is a single one-line action, which matches the test description better — and the
production analogue is the sidecar/init-container pattern in Kubernetes.

## Alternative considered: bind mount

```
docker run -d --name devops-hello-demo \
    -p 8890:8080 \
    -v "$PWD/.bin:/opt/bin:ro" \
    --restart unless-stopped devops-hello:1.0.0
```

Then the swap is `cp host/hello /opt/bin/hello && docker restart devops-hello-demo`. Simpler
in principle, but it requires the Dockerfile to expose a mount target and the operator to keep
that directory in sync with the image. We picked `docker cp` because it works on any container
with no special run flags, while demonstrating the same in-container supervisor signal.
