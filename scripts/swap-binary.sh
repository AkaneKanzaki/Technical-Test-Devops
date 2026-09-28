#!/bin/sh
# Hot-swap demo: build a new binary, cp it into the running container,
# signal PID 1 to respawn with the new file. No image rebuild, no
# container removal.
#
# usage: swap-binary.sh [container] [version] [binary-out] [port]

set -eu

NAME="${1:-devops-hello}"      # running container name
VERSION="${2:-1.0.1}"          # version baked into the new binary
BIN_OUT="${3:-.bin/hello-v2}"
PORT="${4:-8888}"              # host port the container is published on

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 1) build the new binary on the host
./scripts/build.sh "$VERSION" "$BIN_OUT"

# 2) sanity-check the destination container
if ! docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
    echo "$NAME is not running" >&2
    exit 1
fi

# 3) cp the binary into the container at the same path
docker cp "$BIN_OUT" "${NAME}:/usr/local/bin/hello"

# 4) signal PID 1. tini forwards SIGHUP to entrypoint.sh, which kills the
#    running child and exits the loop. tini restarts the loop and the loop
#    re-spawns the (now-new) binary.
T0=$(date +%s%3N)
docker exec "$NAME" sh -c 'kill -HUP 1' >/dev/null 2>&1 || true

# 5) wait until the new version answers /version
printf 'waiting for version=%s on http://localhost:%s ...' "$VERSION" "$PORT"
for _ in $(seq 1 100); do
    got=$(curl -s --max-time 1 "http://localhost:${PORT}/version" 2>/dev/null || true)
    if [ "$got" = "$VERSION" ]; then
        T1=$(date +%s%3N)
        printf ' ok in %s ms\n' "$((T1 - T0))"
        printf 'curl /        -> %s' "$(curl -s "http://localhost:${PORT}/")"
        printf 'curl /version -> %s\n' "$(curl -s "http://localhost:${PORT}/version")"
        exit 0
    fi
    sleep 0.05
done

echo " timeout" >&2
exit 2
