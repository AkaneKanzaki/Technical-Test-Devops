# devops-hello

Go HTTP server, multi-stage Docker image, hot-swap binary mechanism, and a Jenkins
pipeline that takes it from push to running production. Built for the DevOps
technical test in `Submission.pdf`.

## What's inside

```
main.go                 # the HTTP server (Hello, DevOps! version=...)
main_test.go            # 1+2 small tests, run locally and in CI
go.mod                  # module devops-hello, Go 1.27

Dockerfile              # multi-stage: golang:1.27-alpine -> alpine:3.20 + tini
entrypoint.sh           # PID 1 supervisor, hot-swap aware

Jenkinsfile             # declarative pipeline: checkout / test / build / deploy / verify
jenkins.Dockerfile      # jenkins-custom:lts = jenkins/jenkins:lts + Go 1.27 + docker CLI

scripts/
├── build.sh              # build a static Go binary with -X main.version=...
├── run.sh                # local helper: docker run --name devops-hello --restart unless-stopped
├── swap-binary.sh        # hot-swap: docker cp + SIGHUP into the supervisor
├── swap-measure.sh       # hammer /version across a swap and report the impact
├── deploy.sh             # blue/green + healthcheck + rollback, called by the pipeline
├── start-jenkins.sh      # launch jenkins-custom:lts with docker socket bind-mounted
└── seed-jenkins-repo.sh  # copy the current commit into the Jenkins controller's git source

docs/
├── build.md            # Part I write-up (size, base image, build command)
├── deploy.md           # Part II write-up (run, hot-swap, curl before/after)
└── cicd.md             # Part III write-up (pipeline, rollback, push-simulation)

screenshots/                      # evidence, named by the part it backs
├── part1-build.log             # multi-stage build output (docker build --no-cache)
├── part1-image-evidence.log    # size, layer breakdown, static-binary proof, version proof
├── part2-hotswap.log           # before/after + proof the container was never restarted
├── part2-downtime.log          # request loop during the swap: 0 failures, 0.76s worst stall
├── part3-pipeline-green.log    # full Jenkins console of the green run (build #12)
├── part3-rollback.log          # broken image rejected, production left serving
├── part3-jenkins-job-overview.png  # Stage View - build #12 all green
├── part3-jenkins-build-12.png      # build #12 detail (commit, revision, duration)
├── part3-jenkins-console-output.png# console, scrolled to "Finished: SUCCESS"
└── app-running.png             # the deployed app answering on :8888

.gitignore / .dockerignore
```

## Quickstart

Prereqs: Docker Desktop and Go 1.27 are on PATH. Nothing else.

```
go test -v ./...

docker build -t devops-hello:1.0.0 --build-arg VERSION=1.0.0 .
docker run -d --name devops-hello -p 8888:8080 --restart unless-stopped devops-hello:1.0.0

curl -s http://localhost:8888/         # -> Hello, DevOps! version=1.0.0
curl -s http://localhost:8888/health   # -> ok
curl -s http://localhost:8888/version  # -> 1.0.0

./scripts/swap-binary.sh devops-hello 1.0.1 .bin/hello-v2
curl -s http://localhost:8888/version  # -> 1.0.1
```

`./scripts/swap-binary.sh` builds a new binary on the host, `docker cp`s it
into the running container, sends SIGHUP to the supervisor inside, and waits
for `/version` to flip. No image rebuild. No container removal. Tested to flip
in roughly two seconds end-to-end.

See `docs/build.md`, `docs/deploy.md`, and `docs/cicd.md` for the detailed
write-up that backs each part of the test.

## Part-by-part deliverables

| Part | Deliverable                                                                    | Where                                  |
|------|-------------------------------------------------------------------------------|----------------------------------------|
| I    | Dockerfile (multi-stage, static binary, minimal base)                          | `Dockerfile`                           |
| I    | Build command                                                                  | `docs/build.md` (and `Jenkinsfile`)    |
| I    | Final image size + reasoning                                                   | `docs/build.md`, `screenshots/part1-image-evidence.log` |
| II   | Run command + --restart policy                                                 | `scripts/run.sh`, `docs/deploy.md`     |
| II   | Hot-swap mechanism (docker cp + SIGHUP, no rebuild, no container removal)      | `entrypoint.sh`, `scripts/swap-binary.sh`, `docs/deploy.md` |
| II   | curl before / after, downtime measurement, why this approach                   | `docs/deploy.md`                       |
| III  | Pipeline stages: Checkout / Test / Build Image / Deploy / Verify              | `Jenkinsfile`, `docs/cicd.md`          |
| III  | No hardcoded secrets; Jenkins credentials binding path documented              | `docs/cicd.md`                         |
| III  | Screenshot of one successful end-to-end pipeline run                          | `screenshots/part3-jenkins-job-overview.png` (+ build detail, console) |
| III  | Full console log of the same run                                              | `screenshots/part3-pipeline-green.log` |
| III  | Rollback explanation                                                           | `docs/cicd.md`                         |

## Build, run, deploy on this machine

```
# 1. test
go test -v ./...

# 2. build image
docker build -t devops-hello:1.0.0 --build-arg VERSION=1.0.0 .

# 3. run as long-lived service
./scripts/run.sh devops-hello 1.0.0 8888
curl -s http://localhost:8888/version

# 4. hot-swap a bug fix in
./scripts/swap-binary.sh devops-hello 1.0.1 .bin/hello-v2
curl -s http://localhost:8888/version   # now 1.0.1

# 5. start the CI side
docker build -f jenkins.Dockerfile -t jenkins-custom:lts .
./scripts/start-jenkins.sh jenkins jenkins_home
docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword
```

## Why each tool was chosen (and trade-offs)

- **alpine:3.20** for the runtime: same constraint set as `scratch` or
  `distroless/static` minus the operational hassle of having no shell. We
  need a shell to handle hot-swap signals, so an extra ~3 MB buys us the
  whole hot-swap story. Documented in `docs/build.md`.
- **Docker cp + in-container SIGHUP** for hot-swap rather than bind-mount
  volume: works on any container, no host layout needed, single file
  replacement. Documented in `docs/deploy.md`.
- **Docker socket bind-mounted into Jenkins** rather than SSH agent: this is
  single-machine, and Docker Desktop's docker engine is reachable via the
  socket. Trade-off noted in `docs/cicd.md`.
- **Custom Jenkins image** (`jenkins-custom:lts`) baking in Go 1.27 and the
  static docker CLI: makes `start-jenkins.sh` reproducible. Build with
  `docker build -f jenkins.Dockerfile -t jenkins-custom:lts .`.

## Notes for the reviewer

- Comments in code are English-only.
- `.gitignore` excludes Go build outputs (`*.exe`, `*.test`), coverage
  artifacts, vendor/ build directories, IDE state, OS junk, and Jenkins
  workspace dumps so nothing cache-y ever lands in the repo.
- `.dockerignore` excludes the same plus docs/screenshots so image
  layers are not bloated by markdown.
- The Go binary in the runtime image is fully static (`CGO_ENABLED=0`,
  `-s -w`, `-X main.version=...`); nothing in the host's glibc/musl is
  needed.
