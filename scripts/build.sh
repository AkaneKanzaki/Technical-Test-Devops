#!/bin/sh
# Build the Go binary on the host with an injectable version.
# CGO is off and the binary is fully static. The output is used as the
# target for docker cp into the running container.
#
# usage: build.sh [version] [output-path]

set -eu

VERSION="${1:-dev}"
OUT="${2:-.bin/hello}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

mkdir -p "$(dirname "$OUT")"

CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -trimpath \
    -ldflags "-s -w -X main.version=${VERSION}" \
    -o "$OUT" .

echo "built $OUT (version=$VERSION)"
