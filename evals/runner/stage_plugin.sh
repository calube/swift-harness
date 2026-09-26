#!/usr/bin/env bash
# Stages this checkout for `claude plugin eval`, which wants the eval cases inside the plugin root:
# `--eval-dir` refuses `..`, and an `evals` link inside plugin/ is refused when a case runs. The
# stage mirrors the repo layout that the scaffolds walk up to find: <stage>/plugin with a real
# copy of evals/ inside it, and <stage>/examples, <stage>/.gitignore and <stage>/evals beside it.
#
# Run: evals/runner/stage_plugin.sh <stage-dir> [<tag> <split-tag> <new-tag>]...
#   then: cd <stage-dir>/plugin && claude plugin eval . --tag <new-tag> ...
# Each triple adds <new-tag> to every case tagged both <tag> and <split-tag>, because `--tag`
# matches any of its tags, not all. The tags live only in the stage.
set -euo pipefail

stage="${1:?usage: stage_plugin.sh <stage-dir> [<tag> <split-tag> <new-tag>]...}"
shift
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

mkdir -p "$stage"
rsync -a --delete --exclude .build --exclude .swiftpm "$repo/plugin/" "$stage/plugin/"
rsync -a --delete --exclude results "$repo/evals/" "$stage/plugin/evals/"
rsync -a --delete --exclude .build "$repo/examples/" "$stage/examples/"
/bin/cp -f "$repo/.gitignore" "$stage/.gitignore"
ln -sfn plugin/evals "$stage/evals"

while [ $# -ge 3 ]; do
  tag="$1" split="$2" new="$3"
  shift 3
  grep -rl --include=case.yaml -e "$tag" "$stage/plugin/evals/cases" | while read -r f; do
    if grep -Eq "tags: \[.*\b$split\b" "$f" && grep -Eq "tags: \[.*\b$tag\b" "$f"; then
      sed -i '' -E "s/^(tags: \[.*)\]$/\1, $new]/" "$f"
    fi
  done
done

# The gate binary is cached by a hash of the plugin path, so build it for the stage once, here,
# rather than inside the first case's scaffold.
"$stage/plugin/bin/swiftgate" --version >/dev/null
