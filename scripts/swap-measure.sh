#!/bin/sh
# Prove the hot-swap does not drop requests.
#
# Hammers /version in a tight loop, fires the swap partway through, then
# reports how many requests failed and at which request the version flipped.
# The "longest gap" is the worst-case time between two consecutive responses,
# which is the closest shell-level proxy for user-visible downtime.
#
# usage: swap-measure.sh [container] [new-version] [port]

set -eu

NAME="${1:-devops-hello}"
NEW_VERSION="${2:-1.0.1}"
PORT="${3:-8888}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

mkdir -p .bin
RESULTS=".bin/swap-load.txt"
STOP=".bin/swap-load.stop"
: > "$RESULTS"
rm -f "$STOP"

# --- background load generator -------------------------------------------
(
    while [ ! -f "$STOP" ]; do
        ts=$(date +%s%3N)
        body=$(curl -s --max-time 2 "http://localhost:${PORT}/version" 2>/dev/null || true)
        [ -z "$body" ] && body="ERR"
        printf '%s %s\n' "$ts" "$body" >> "$RESULTS"
    done
) &
LOAD_PID=$!

# Let a baseline build up before disturbing anything.
sleep 3
BEFORE=$(tail -1 "$RESULTS" | awk '{print $2}')
printf 'baseline version: %s\n' "$BEFORE"

# --- trigger the swap ----------------------------------------------------
./scripts/swap-binary.sh "$NAME" "$NEW_VERSION" ".bin/hello-v2" "$PORT"

# Keep sampling briefly after the flip so the window covers the transition.
sleep 3
touch "$STOP"
wait "$LOAD_PID" 2>/dev/null || true
rm -f "$STOP"

# --- analyse -------------------------------------------------------------
awk -v new="$NEW_VERSION" '
{
    n++
    if ($2 == "ERR") err++
    else if ($2 == new) newc++
    else oldc++
    if (prev != "") { gap = $1 - prev; if (gap > maxgap) maxgap = gap }
    if (prev == "") first = $1
    prev = $1
    if ($2 == new && flip == 0) flip = n
}
END {
    printf "\n--- hot-swap impact ---\n"
    printf "requests observed      : %d\n", n
    printf "responses ok           : %d\n", n - err
    printf "responses failed       : %d\n", err
    printf "  served old version   : %d\n", oldc
    printf "  served new version   : %d\n", newc
    printf "version flipped at     : request #%d\n", flip
    printf "longest gap between    : %d ms  (worst-case user-visible stall)\n", maxgap
    printf "total window           : %d ms\n", prev - first
    if (err == 0)
        printf "verdict                : no request failed during the swap\n"
    else
        printf "verdict                : %d request(s) failed\n", err
}
' "$RESULTS"
