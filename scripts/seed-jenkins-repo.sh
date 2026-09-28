#!/bin/sh
# Seed the Jenkins controller's git source with this working tree.
#
# Jenkins reads the pipeline from a bare repo inside its own jenkins_home.
# This script recreates that bare repo from the current checkout and copies it
# into the running Jenkins container, so no remote has to be configured on
# your local repo. Run it after any commit you want the pipeline to pick up.
#
# usage: seed-jenkins-repo.sh [jenkins-container] [scratch-bare-repo-path]

set -eu

# Git Bash rewrites Unix-looking paths in docker args; keep them literal.
MSYS_NO_PATHCONV=1
export MSYS_NO_PATHCONV

CONTAINER="${1:-jenkins}"
BARE="${2:-/tmp/devops-hello.git}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 1) recreate the bare repo from the current commit
rm -rf "$BARE"
git init -q -b main --bare "$BARE"
git push -q "$BARE" HEAD:refs/heads/main

# 2) copy it into the Jenkins container
docker exec -u root "$CONTAINER" rm -rf /var/jenkins_home/repo.git
docker cp "$BARE" "$CONTAINER:/var/jenkins_home/repo.git"
docker exec -u root "$CONTAINER" chown -R jenkins:jenkins /var/jenkins_home/repo.git

# 3) let git inside the container trust the path (otherwise it refuses to
#    read a repo owned by a different uid)
docker exec "$CONTAINER" git config --global --add safe.directory /var/jenkins_home/repo.git

echo "seeded $(git rev-parse --short HEAD) into ${CONTAINER}:/var/jenkins_home/repo.git"
