#!/bin/sh
# Blue/Green deploy of devops-hello.<IMAGE_TAG> in front of whichever
# devops-hello container is currently serving the host on PROD_PORT.
#
# Strategy:
#   1. Start the new tag as a "candidate" on port 8081.
#   2. Health-check the candidate via curl /health.
#   3. Healthy -> stop the old "production" container and rename the
#      candidate to devops-hello (host PROD_PORT -> container 8080).
#   4. Unhealthy -> remove the candidate, leave production untouched,
#      exit 1 so Jenkins marks the stage failed.
#
# No secrets are read from the environment here. Image-tag comes in on
# argv from the Jenkinsfile. Credentials (registry/login) live in the
# Jenkins credentials store.

set -eu

IMAGE_TAG="${1:-1.0.0}"
PROD_NAME="devops-hello"
CAND_NAME="devops-hello-cand"
CAND_PORT="8889"
PROD_PORT_EXT="8888"
HEALTH_TIMEOUT=10

# Sanity check the target image exists locally. (We do not push to a
# registry in this test - see docs/cicd.md.)
if ! docker image inspect "${IMAGE_TAG}" >/dev/null 2>&1; then
    echo "deploy: image ${IMAGE_TAG} not present locally" >&2
    exit 1
fi

# If we are running inside a container (Jenkins controller), the published
# port on the host is reachable via host.docker.internal, not localhost.
# On a bare metal host this would fall back to 127.0.0.1.
if [ -f /.dockerenv ] || grep -q '/docker\|/lxc' /proc/1/cgroup 2>/dev/null; then
    CAND_HOST="${DOCKER_HOST_ADDR:-host.docker.internal}"
else
    CAND_HOST="localhost"
fi

# Always start from a clean slate for the candidate.
docker rm -f "$CAND_NAME" >/dev/null 2>&1 || true

echo "deploy: starting candidate ${CAND_NAME} from ${IMAGE_TAG}"
docker run -d \
    --name "$CAND_NAME" \
    -p "${CAND_PORT}:8080" \
    --restart unless-stopped \
    "${IMAGE_TAG}"

# Health-check loop.
deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 "http://${CAND_HOST}:${CAND_PORT}/health" 2>/dev/null || echo 0)
    if [ "$code" = "200" ]; then
        echo "deploy: candidate healthy at ${CAND_HOST}:${CAND_PORT}"
        break
    fi
    sleep 0.5
done

if [ "$code" != "200" ]; then
    echo "deploy: candidate never became healthy at ${CAND_HOST}:${CAND_PORT} (last code=$code), rolling back" >&2
    docker rm -f "$CAND_NAME" >/dev/null 2>&1 || true
    exit 1
fi

# Note the previous production's image tag so we can print it in logs.
prev_image=""
if docker inspect "$PROD_NAME" >/dev/null 2>&1; then
    prev_image=$(docker inspect "$PROD_NAME" -f '{{.Config.Image}}')
fi

# Swap: stop old prod, restart candidate as production on PROD_HOST:PROD_PORT.
echo "deploy: stopping previous production (image=${prev_image:-none})"
docker rm -f "$PROD_NAME" >/dev/null 2>&1 || true

docker run -d \
    --name "$PROD_NAME" \
    -p "${PROD_PORT_EXT:-8888}:8080" \
    --restart unless-stopped \
    "${IMAGE_TAG}"

# Candidate is now redundant: prod has the same image serving on PROD_PORT.
docker rm -f "$CAND_NAME" >/dev/null 2>&1 || true

# Final probe so the caller sees a 200 with the right version.
final=$(curl -s --max-time 2 "http://${PROD_HOST:-localhost}:${PROD_PORT_EXT:-8888}/version" || echo "")
echo "deploy: production is ${IMAGE_TAG}, /version -> ${final}"
