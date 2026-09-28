# Evidence index

Every file here backs a specific deliverable in the technical test. Files are named
`part<N>-*` by the part of the brief they answer; `app-running.png` spans Parts II and III.

| File | Part | What it proves |
|------|------|----------------|
| `part1-build.log` | I | `docker build --no-cache` output: both stages run, final image tagged. |
| `part1-image-evidence.log` | I | Image size, layer-by-layer breakdown, `ldd` showing a fully static binary, version-injection proof, image config. |
| `part2-hotswap.log` | II | Before/after `curl`, plus seven identity signals (container ID, `Created`, `StartedAt`, `RestartCount`, image ID, supervisor PID, binary SHA) showing a genuinely in-place swap. |
| `part2-downtime.log` | II | A request loop running across a swap: 30 requests, 0 failures, 757 ms worst-case stall, `RestartCount=0`. |
| `part3-pipeline-green.log` | III | Full Jenkins console for build #12 — checkout, test, build image, deploy, verify, `Finished: SUCCESS`. |
| `part3-rollback.log` | III | A deliberately broken image rejected by `deploy.sh`; production kept serving the previous version and the candidate was cleaned up. |
| `part3-jenkins-job-overview.png` | III | Jenkins Stage View — build #12 green across all seven stages. |
| `part3-jenkins-build-12.png` | III | Build #12 detail: revision, repository, commit message, duration. |
| `part3-jenkins-console-output.png` | III | Console scrolled to the end, showing `Finished: SUCCESS`. |
| `app-running.png` | II / III | The deployed app answering on `:8888` with the version tag produced by the pipeline. |

Each log starts with a `captured: <ISO-8601 UTC>` line. If a log's content no longer matches
the live system, that header is how you tell — regenerate rather than trust a stale log.

## Reproducing

```sh
# Part I
docker build -t devops-hello:1.0.0 --build-arg VERSION=1.0.0 .

# Part II (use a scratch container so production is untouched)
./scripts/run.sh devops-hello-demo 1.0.0 8890
./scripts/swap-binary.sh devops-hello-demo 1.0.1 .bin/hello-v2 8890
./scripts/swap-measure.sh devops-hello-demo 1.0.2 8890

# Part III
./scripts/deploy.sh devops-hello:<tag>     # healthy tag -> promotes
./scripts/deploy.sh devops-hello:broken    # unhealthy  -> rolls back, exit 1
```

The Jenkins screenshots require the controller from `scripts/start-jenkins.sh`, the current
commit seeded with `scripts/seed-jenkins-repo.sh`, and a green build of the `devops-hello` job.

```sh
./scripts/start-jenkins.sh jenkins jenkins_home   # first time only
./scripts/seed-jenkins-repo.sh jenkins            # after any commit
curl -X POST http://localhost:8080/job/devops-hello/build
```
