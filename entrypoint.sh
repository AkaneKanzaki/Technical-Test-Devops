#!/bin/sh
# Supervisor for the hello binary. Two modes:
#   1) flag pass-through: if args are passed (e.g. --print-version), run the
#      binary once and exit. Used for ad-hoc CLI checks.
#   2) supervisor: spawn the binary and re-spawn it whenever it exits.
#
# Hot-swap protocol: docker cp a new /usr/local/bin/hello, then send SIGHUP.
# The handler stops the running child and the loop re-spawns the new file
# IN PLACE. This process never exits, so the container's PID 1 stays alive
# and Docker never has to restart the container.
#
# TERM/INT still exit, so `docker stop` shuts the container down normally.

set -eu

BIN=/usr/local/bin/hello
CHILD=""
SWAP=0

# If the operator passed anything (e.g. --print-version), just exec once.
if [ "$#" -gt 0 ]; then
    exec "$BIN" "$@"
fi

# SIGHUP means "the binary on disk was replaced": stop the child, and let the
# main loop pick up the new file on its next iteration.
on_hup() {
    SWAP=1
    if [ -n "$CHILD" ] && kill -0 "$CHILD" 2>/dev/null; then
        kill -TERM "$CHILD" 2>/dev/null || true
    fi
}

# TERM/INT mean "shut down": stop the child and leave.
on_term() {
    if [ -n "$CHILD" ] && kill -0 "$CHILD" 2>/dev/null; then
        kill -TERM "$CHILD" 2>/dev/null || true
        wait "$CHILD" 2>/dev/null || true
    fi
    exit 0
}

trap on_hup HUP
trap on_term TERM INT

while true; do
    "$BIN" &
    CHILD=$!
    rc=0
    wait "$CHILD" || rc=$?

    if [ "$SWAP" = "1" ]; then
        SWAP=0
        printf 'supervisor: binary replaced, respawning\n' >&2
        continue
    fi

    printf 'supervisor: child exited rc=%d, respawning in 1s\n' "$rc" >&2
    sleep 1
done
