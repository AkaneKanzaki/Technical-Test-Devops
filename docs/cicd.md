# Part III — CI/CD with Jenkins

## Pipeline

`Jenkinsfile` is a declarative pipeline with these stages:

| Stage          | Action                                                                                       |
|----------------|----------------------------------------------------------------------------------------------|
| Checkout       | `checkout scm` against `file:///var/jenkins_home/repo.git` (set up by `scripts/start-jenkins.sh`). |
| Test           | `go vet ./...` and `go test ./...`. Failure here fails the build and stops the pipeline.     |
| Build Image    | `docker build -t devops-hello:$BUILD_NUMBER-$GIT_COMMIT_8 .` plus `docker images` for proof.  |
| Deploy         | `scripts/deploy.sh devops-hello:$TAG`. Blue/green + healthcheck + automatic rollback.        |
| Verify         | `curl /health` and `curl /version` against the running prod (via `host.docker.internal`).    |

The image tag (and therefore the version baked into the binary) is
`$BUILD_NUMBER-$GIT_COMMIT_8`, e.g. `devops-hello:12-325b7f85`. That tag appears in
`GET /version` exactly as expected.

## Credentials & secrets

- One Jenkins credential ID `repo-https` would be used to authenticate against a
  private repo URL. In this test the SCM URL is `file:///var/jenkins_home/repo.git`
  so no auth is needed in practice, but a credential **could** be wired in by
  setting `credentialsId` on the `<UserRemoteConfig>` in the job config XML. See
  `scripts/start-jenkins.sh` for the docker-socket bind that lets the pipeline run
  `docker` from inside Jenkins.
- Registry push (Step 10 in the brief) is **skipped** and explicitly called out
  here. To enable later, store a `Username/Password` credential in Jenkins
  Credentials with ID `registry-creds` and `docker login` from the agent before
  `docker push` is added to the Build Image stage. There is no environment
  registry available in this test.
- No tokens, registry passwords, or SSH keys live in `Jenkinsfile`.

## End-to-end run (build #12, all stages green)

Build number `12`, commit `325b7f8`, wall-clock `29.0 s`, result `SUCCESS`.

Evidence captured from the running Jenkins UI:

| File | Shows |
|------|-------|
| `screenshots/part3-jenkins-job-overview.png` | Stage View — build #12 green across all 7 stages |
| `screenshots/part3-jenkins-build-12.png`     | Build detail: revision, repository, commit, duration |
| `screenshots/part3-jenkins-console-output.png` | Console scrolled to `Finished: SUCCESS` |
| `screenshots/app-running.png`          | The deployed app answering on `:8888` with the pipeline's version tag |
| `screenshots/part3-pipeline-green.log` | Full raw console log |

Console excerpt (key lines from `screenshots/part3-pipeline-green.log`):

```
[Pipeline] stage
[Pipeline] { (Test)
[Pipeline] sh
+ go vet ./...
[Pipeline] sh
+ go test -v ./...
=== RUN   TestRootHandler
--- PASS: TestRootHandler (0.00s)
=== RUN   TestHealthHandler
--- PASS: TestHealthHandler (0.00s)
=== RUN   TestVersionEndpoint
--- PASS: TestVersionEndpoint (0.00s)
PASS
ok  	devops-hello	0.003s
[Pipeline] }
[Pipeline] stage
[Pipeline] { (Build Image)
[Pipeline] sh
+ docker build -t devops-hello:12-325b7f85 --build-arg VERSION=12-325b7f85 .
...
Successfully built ee0ff3b2aa72
Successfully tagged devops-hello:12-325b7f85
[Pipeline] sh
+ docker images
+ grep devops-hello
devops-hello      12-325b7f85   ee0ff3b2aa72   Less than a second ago   22.4MB
devops-hello      1.0.0         7795b72e157d   2 minutes ago            22.4MB
devops-hello      11-93d229fe   627fb1ff6fb3   33 minutes ago           22.4MB
[Pipeline] }
[Pipeline] stage
[Pipeline] { (Deploy)
[Pipeline] sh
+ chmod +x scripts/build.sh scripts/deploy.sh scripts/run.sh scripts/start-jenkins.sh scripts/swap-binary.sh scripts/swap-measure.sh
[Pipeline] sh
+ ./scripts/deploy.sh devops-hello:12-325b7f85
deploy: starting candidate devops-hello-cand from devops-hello:12-325b7f85
deploy: candidate healthy at host.docker.internal:8889
deploy: stopping previous production (image=devops-hello:11-93d229fe)
deploy: production is devops-hello:12-325b7f85, /version -> 12-325b7f85
[Pipeline] }
[Pipeline] stage
[Pipeline] { (Verify)
[Pipeline] sh
+ curl -sf http://host.docker.internal:8888/health
ok
[Pipeline] sh
+ curl -s http://host.docker.internal:8888/version
12-325b7f85
[Pipeline] }
[Pipeline] stage
[Pipeline] { (Declarative: Post Actions)
[Pipeline] echo
pipeline green: devops-hello:12-325b7f85 is serving on host.docker.internal:8888
[Pipeline] }
Finished: SUCCESS
```

## Push to registry — simulated

The brief asks for a registry credential and a push step. We don't have a
registry in this environment, so the Jenkinsfile does the local-only equivalent:
the Build Image stage prints `docker images` showing the freshly tagged image.
Switching on push is a single-stage change:

```
stage('Push') {
    steps {
        withCredentials([usernamePassword(credentialsId: 'registry-creds',
                                          usernameVariable: 'REG_USER',
                                          passwordVariable: 'REG_PASS')]) {
            sh 'echo $REG_PASS | docker login -u $REG_USER --password-stdin registry.example.com'
            sh "docker push ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
        }
    }
}
```

The Jenkins credentials binding for `registry-creds` is the only place the
registry username/password lives. The rest of the pipeline never sees them.

## How rollback works

Two layers of protection, both deliberate:

### 1. `scripts/deploy.sh` will not promote a bad candidate

The script:

1. Removes any leftover `devops-hello-cand`.
2. Starts the new tag as `devops-hello-cand` on a candidate port (8889).
3. Polls `host.docker.internal:8889/health` until it returns `200` or 10 seconds elapse.
4. **Only if the candidate is healthy** does it `docker rm -f` the previous
   production container and start the new production on `host.docker.internal:8888`.
5. If the candidate never becomes healthy, `docker rm -f devops-hello-cand`,
   `exit 1`. **The previously-running production container is never touched,
   so the user-facing service keeps serving whatever version was last good**.

#### Verified, not just described

`screenshots/part3-rollback.log` records an actual failed deploy. A deliberately
broken image (entrypoint exits 3 immediately) was deployed while production was
serving `12-325b7f85`:

```
$ ./scripts/deploy.sh devops-hello:broken
deploy: starting candidate devops-hello-cand from devops-hello:broken
deploy: candidate never became healthy at localhost:8889 (last code=0000), rolling back

exit code: 1

$ curl -s http://localhost:8888/version      # production, after the failed deploy
12-325b7f85
$ docker ps --filter name=devops-hello-cand  # leftover candidate?
  none - candidate was cleaned up
```

Production kept serving the previous good version, the candidate was cleaned up,
and the script exited non-zero so Jenkins would have failed the stage.

### 2. The pipeline `failure` post-action echoes a clear message

If `deploy.sh` exits non-zero, the Jenkins stage is marked failed, every later
stage (Verify, declarative post) is skipped, and the failure post-action echoes:

```
pipeline failed - production container from the previous good build is left untouched
```

The operator can `docker ps --filter name=devops-hello` and confirm the previous
image is still serving.

### 3. Rolling back to a known-good build number

Once a bad build is shipped, the rollback path is just rebuilding from the
last green commit. Re-run with `$BUILD_NUMBER`/`GIT_COMMIT_SHORT` pointing at
the previous good commit, or call `scripts/deploy.sh devops-hello:<prev>` by
hand:

```
./scripts/deploy.sh devops-hello:9-5ead34fe
```

That promotes the old image as production through the same blue/green flow.

### 4. Last-resort, manual escape hatch

```
docker rm -f devops-hello
./scripts/run.sh devops-hello <previous-good-tag> 8888
```

Documented in `scripts/run.sh`. This skips the candidate dance; the previous
container is just replaced with the old image.

## Local proxy fact: why `host.docker.internal:8888`

When Jenkins runs in a container on Docker Desktop for Windows, the published
host ports are reachable from inside Jenkins only via the
`host.docker.internal` magic name (resolves to `192.168.65.254`). Plain
`localhost` inside Jenkins refers to the Jenkins container's own loopback, not
the host. Both `scripts/deploy.sh` and the Verify stage detect this and use
`host.docker.internal`. On a non-containerised agent, the env override
`DOCKER_HOST_ADDR=localhost` (or unset) keeps the same code working on a
bare-metal host.

## Demo command set

```
# 1) build custom image (jenkins + go + docker CLI)
docker build -f jenkins.Dockerfile -t jenkins-custom:lts .

# 2) start Jenkins (first time only)
./scripts/start-jenkins.sh jenkins jenkins_home

# 3) get the admin password and unlock Jenkins in the browser
docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword

# 4) install the plugins once (see scripts/start-jenkins.sh for the
#    required set, or follow "Setup Wizard" and select the suggested list)

# 5) seed the current commit into the Jenkins controller's git source.
#    This creates a throwaway bare repo, copies it into the container and
#    fixes ownership, so no git remote has to be configured locally.
./scripts/seed-jenkins-repo.sh jenkins

# 6) create the pipeline job once (or hit "Save" after creating via UI
#    with these SCM fields: file:///var/jenkins_home/repo.git,
#    branches */main, scriptPath Jenkinsfile)

# 7) run a build
curl -X POST http://localhost:8080/job/devops-hello/build

# 8) tail the green build
curl -u admin:<token> http://localhost:8080/job/devops-hello/lastBuild/consoleText
```

Re-builds after the first run are a single `git push` (to the bare repo)
followed by a hit to `/job/devops-hello/build`.
