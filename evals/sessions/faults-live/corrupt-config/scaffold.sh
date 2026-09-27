#!/usr/bin/env bash
# SampleApp, then this case's setup. The shared scaffold walks up from its own path, so this
# script finds the repo root the same way and runs it from there.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
while [ ! -f "$repo_root/plugin/.claude-plugin/plugin.json" ]; do
  [ "$repo_root" = "/" ] && { echo "scaffold: no plugin root above the case" >&2; exit 1; }
  repo_root="$(dirname "$repo_root")"
done
bash "$repo_root/evals/scaffold/sampleapp.sh"
git() { command git -c user.name=eval -c user.email=eval@example.invalid "$@"; }
printf 'schema = [[[\n' > .swiftgate.toml
