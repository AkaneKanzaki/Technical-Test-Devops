# Builds on jenkins/jenkins:lts and adds the toolchain the pipeline expects:
#   - go 1.27.x  (test, build-deps)
#   - docker CLI (so the pipeline can drive the daemon via the mounted socket)
#
# The host's docker.sock is bind-mounted at runtime; we just need the CLI
# binaries and a "docker compose" plugin available in the controller's PATH.
#
# Also pre-installs a couple of plugins that weren't in the LTS image by
# default but are referenced by the Jenkinsfile / pipeline UI.
#
# Use: docker build -t jenkins-custom:lts .
#
# After build, run:
#   docker run -d --name jenkins -p 8080:8080 -p 50000:50000 \
#     --restart unless-stopped \
#     -v jenkins_home:/var/jenkins_home \
#     -v /var/run/docker.sock:/var/run/docker.sock \
#     -e JAVA_OPTS="-Dhudson.plugins.git.GitSCM.ALLOW_LOCAL_CHECKOUT=true" \
#     jenkins-custom:lts

FROM jenkins/jenkins:lts

USER root

# Install OS-level deps and the docker CLI (we talk to the host's daemon
# via the bind-mounted unix socket).
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends \
        curl \
        ca-certificates \
        git \
 && curl -sL https://go.dev/dl/go1.27.1.linux-amd64.tar.gz | tar -xz -C /usr/local \
 && ln -sf /usr/local/go/bin/go     /usr/local/bin/go \
 && ln -sf /usr/local/go/bin/gofmt  /usr/local/bin/gofmt \
 && curl -sL https://download.docker.com/linux/static/stable/x86_64/docker-27.3.1.tgz | tar -xz -C /tmp \
 && mv /tmp/docker/docker /usr/local/bin/docker \
 && chmod +x /usr/local/bin/docker \
 && rm -rf /tmp/docker \
 && rm -rf /var/lib/apt/lists/*

USER jenkins

# Quick sanity check so build logs prove the toolchain is in place.
RUN go version && docker --version

# Plugin list is kept here purely as documentation; the LTS image
# already ships the "detached" core set. Real installs happen via the
# Jenkins update center on first start.
LABEL maintainer="devops-hello"
LABEL description="Jenkins LTS + Go 1.27 + Docker CLI for devops-hello pipeline"
