#!/usr/bin/env bash
# SampleApp on a feature branch that commits this case's change.patch over main.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$here"
while [ ! -f "$repo_root/plugin/.claude-plugin/plugin.json" ]; do
  [ "$repo_root" = "/" ] && { echo "scaffold: no plugin root above the case" >&2; exit 1; }
  repo_root="$(dirname "$repo_root")"
done
bash "$repo_root/evals/scaffold/sampleapp.sh"
git() { command git -c user.name=eval -c user.email=eval@example.invalid "$@"; }
git switch -q -c change
git apply "$here/change.patch"
git add -A
git commit -qm "$(cat "$here/commit-message.txt")"
