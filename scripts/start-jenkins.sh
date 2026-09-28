#!/bin/sh
# Launch the custom-built Jenkins image with the host Docker socket
# bind-mounted in. Same-host deploy target: the pipeline uses the docker
# CLI from inside Jenkins to drive the local daemon. jenkins_home is
# persisted in a named volume so credentials survive restarts.

set -eu

NAME="${1:-jenkins}"
DATA_VOLUME="${2:-jenkins_home}"

# Idempotent.
docker rm -f "$NAME" >/dev/null 2>&1 || true

# Pull the custom image if it isn't local already.
if ! docker image inspect jenkins-custom:lts >/dev/null 2>&1; then
    echo "jenkins-custom:lts not built yet; building from jenkins.Dockerfile..."
    docker build -f jenkins.Dockerfile -t jenkins-custom:lts .
fi

docker run -d \
    --name "$NAME" \
    -p 8080:8080 \
    -p 50000:50000 \
    --restart unless-stopped \
    -v "${DATA_VOLUME}:/var/jenkins_home" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -e JAVA_OPTS="-Dhudson.plugins.git.GitSCM.ALLOW_LOCAL_CHECKOUT=true" \
    jenkins-custom:lts

# Open up the bind-mounted docker socket for the jenkins user inside the
# container. In a fully-isolated environment we'd add jenkins to the
# host's docker group instead, but on Docker Desktop for Windows the
# socket's owner is messy and the chmod is harmless.
docker exec -u root "$NAME" sh -c 'chmod 666 /var/run/docker.sock' >/dev/null 2>&1 || true

cat <<EOF
Jenkins started on http://localhost:8080
  unlock with: docker exec ${NAME} cat /var/jenkins_home/secrets/initialAdminPassword
EOF
