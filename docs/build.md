# Part I — Build

## Deliverables

- `Dockerfile` — multi-stage, repo root.
- Build command (used both locally and inside the Jenkins pipeline):
  ```
  docker build -t devops-hello:1.0.0 --build-arg VERSION=1.0.0 .
  ```
- Final image size + reasoning (below).

## Final image size

```
$ docker images devops-hello
IMAGE                ID             DISK USAGE   CONTENT SIZE
devops-hello:1.0.0   9329a2ce7d2c       22.4MB         6.46MB
```

`DISK USAGE` is the uncompressed on-disk footprint reported by Docker 25+.
`CONTENT SIZE` is the compressed size of the image content — that is the number a
registry would actually push over the wire (so this image costs ~6.5 MB per pull).
Both are far smaller than the ~800 MB `golang:1.27-alpine` builder image, because
the builder layers are discarded in a multi-stage build.

Layer breakdown (`docker history devops-hello:1.0.0`):

| Layer | Size   | What it is                          |
|-------|--------|-------------------------------------|
| 1     | 8.47 MB| `alpine:3.20` minirootfs            |
| 2     | 1.52 MB| `ca-certificates` + `tini` + `app` user |
| 3     |  20 kB | `entrypoint.sh`                     |
| 4     | 5.88 MB| `hello` static binary (stripped, `-s -w`) |
| 5     | 4.1 kB | `chmod +x`                          |

Total uncompressed layers: ~15.9 MB. The Hello binary itself is the largest single
layer; the alpine base is small because we use `alpine:3.20` and only `apk add` two
tiny packages. `DISK USAGE` (22.4 MB) is higher than the layer sum because Docker
reports the overlay filesystem's real footprint on this Windows/WSL2 host.

## Base image choice: alpine (not scratch, not distroless)

The brief allows scratch/distroless/alpine. I picked **`alpine:3.20`** for one operational reason:
**the hot-swap mechanism in Part II needs a shell inside the container.** I send a `SIGHUP` to
PID 1 from the host (`docker exec <container> kill -HUP 1`), and a tiny shell wrapper
(`entrypoint.sh`) inside the container catches it and re-spawns the binary.

- `scratch` — no shell, no busybox. Cannot `docker exec` or run a signal-handling supervisor.
  Would require building a static supervisor in Go and putting it as PID 1, which is fine but
  adds compile complexity for no production benefit at this size.
- `distroless/static` — same constraint (no shell). Plus pulls in a debian-sized footprint.
- **`alpine:3.20`** — ~3 MB base, ships `/bin/sh`, busybox `kill` works. Adds ~3 MB cost for
  the ability to hot-swap, which is the headline of Part II.

`tini` (s6-style init) is added on top of alpine so PID 1 properly reaps zombies and forwards
signals to `entrypoint.sh`. The image runs as non-root (`USER app`).

## Why the base layers are dated months ago

`docker history` shows the bottom two rows dated ~5 months before this build:

```
<missing>  5 months ago  ADD alpine-minirootfs-3.20.10-x86_64.tar.gz /   8.47MB
<missing>  5 months ago  CMD ["/bin/sh"]                                   0B
```

That is expected, not a mistake. Those layers belong to `alpine:3.20`, which Alpine
maintainers published on `2026-04-16T23:53:26Z`. `docker pull` preserves the **upstream**
layer timestamps — Docker never rewrites them. Every layer this project builds itself is
dated at build time (the `apk add`, `COPY hello`, `USER app`, `ENTRYPOINT` rows all show
minutes, not months).

This is the correct behaviour and worth keeping:

- It is evidence the base is the genuine upstream artifact, unmodified. A tampered layer
  would produce a different digest (`sha256:d9e853e8…`).
- It is what makes builds reproducible: the same digest yields the same bytes no matter
  when you pull.

The genuine consideration is **freshness, not correctness**. A 5-month-old base carries up
to 5 months of upstream security patches that this image does not have. Note also that
`alpine:3.20` is a *mutable tag* — Alpine can republish it and the tag will resolve to a
different image, so the age shown is only true for the digest currently cached locally.
For a production service the mitigation is to pin the base by digest and rebuild on a
schedule:

```
FROM alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc
```

…then let Renovate or Dependabot raise the digest when upstream publishes a new patch
release. That gives you a deliberate, reviewable base-image bump instead of a silent one.

## Static binary

The build stage forces a fully static binary with no CGO and no dynamic linkage:

```
ENV CGO_ENABLED=0 GOOS=linux GOARCH=amd64
RUN go build -trimpath \
    -ldflags "-s -w -X main.version=${VERSION}" \
    -o /out/hello .
```

`ldflags`:

- `-s` strips the symbol table, `-w` strips DWARF debug info — drops ~30% off the binary size.
- `-X main.version=${VERSION}` overrides the `version` variable at link time, so the resulting
  binary reports exactly the version baked in by the build.

`CGO_ENABLED=0` means the binary does not link against `libc` or any host shared library. You
can copy the same binary into `scratch`, `alpine`, `distroless`, or `debian:slim` and it will
run. Nothing from the builder OS leaks into the runtime image — `scratch` would also have worked
if we'd skipped the hot-swap mechanism.

Proof it is genuinely static — `ldd` finds no dynamic linker to bind to:

```
$ docker run --rm --entrypoint /bin/sh devops-hello:12-325b7f85 -c 'ldd /usr/local/bin/hello'
/lib/ld-musl-x86_64.so.1: /usr/local/bin/hello: Not a valid dynamic program
```

("Not a valid dynamic program" is the expected answer for a static binary — there is no
`PT_INTERP` segment for `ldd` to follow.)

## Version injection

`VERSION` is a `Dockerfile ARG` with default `dev`. Override per build:

```
docker build -t devops-hello:1.0.0 --build-arg VERSION=1.0.0 .
docker build -t devops-hello:dev   --build-arg VERSION=dev   .
```

Verify after build:

```
$ docker run --rm devops-hello:1.0.0 --print-version
1.0.0
```

The `--print-version` flag is a one-shot CLI mode handled inside `entrypoint.sh`: it bypasses
the supervisor loop and just execs the binary with the passed flag.

## No Go toolchain required on the host

The image only contains the compiled binary plus alpine + tini. `docker run --rm devops-hello:1.0.0`
is the only thing required to run it — there is no `go` binary, no Go runtime, no Go env vars
inside the runtime image. Building, however, does need `golang:1.27-alpine` as the builder (CI
runs `docker build`, the host doesn't need Go installed locally for `docker run`).

## Build command (Jenkins uses the same shape)

```
TAG="${BUILD_NUMBER}-$(git rev-parse --short HEAD)"
docker build -t "devops-hello:${TAG}" \
    --build-arg VERSION="${TAG}" \
    .
```
