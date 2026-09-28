#!/bin/sh
# Run the image as a long-running service. Defaults are aligned with
# what docker run -d needs in this test.

set -eu

NAME="${1:-devops-hello}"
TAG="${2:-1.0.0}"
PORT="${3:-8888}"

# Idempotent. Remove any previous instance with the same name.
docker rm -f "$NAME" >/dev/null 2>&1 || true

docker run -d \
    --name "$NAME" \
    -p "${PORT}:8080" \
    --restart unless-stopped \
    "devops-hello:${TAG}"

printf 'started %s on host port %s (image devops-hello:%s)\n' "$NAME" "$PORT" "$TAG"
