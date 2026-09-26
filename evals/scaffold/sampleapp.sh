#!/usr/bin/env bash
# Copies examples/SampleApp into the empty run workspace as its own git repo, with a local bare
# origin so the diff-based tiers can read origin/main.
set -euo pipefail

workspace="$PWD"
# Cases link to this script from inside their own directory, since the runner refuses a
# scaffold path outside the case; walk up from the case to the plugin manifest.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
while [ ! -f "$repo_root/plugin/.claude-plugin/plugin.json" ]; do
  [ "$repo_root" = "/" ] && { echo "scaffold: no plugin root above the case" >&2; exit 1; }
  repo_root="$(dirname "$repo_root")"
done
# The plugin ships from plugin/; the sample app and the ignore rules stay at the repo root.
plugin_root="$repo_root/plugin"

# The eval runner doesn't document the scaffold's environment; this record answers that for the
# runner spike and names variables only, never their values.
mkdir -p "$workspace/.eval"
{
  echo "scaffold_path=${BASH_SOURCE[0]}"
  echo "workspace=$workspace"
  echo "plugin_root=$plugin_root"
  echo "HOME=$HOME"
  env | cut -d= -f1 | sort | tr '\n' ' '
  echo
} >"$workspace/.eval/scaffold-env.txt"

# The run's HOME is scratch, so the shim would start a cold gate build that outlives the run and
# leave every hook off ("enforcement is warming up"). Build or reuse the binary in the real user
# cache, outside the sandbox, and copy it in; the stamp key and cache layout mirror bin/swiftgate.
# The stamp comes too: the shim's source hash depends on the locale, and the hook's locale differs
# from this script's, so without the stamp the hook rehashes to a key that has no binary.
real_home="$(eval echo "~$(id -un)")"
real_cache="$real_home/.cache/swift-harness"
HOME="$real_home" "$plugin_root/bin/swiftgate" --version >"$workspace/.eval/swiftgate-version.txt"
stamp_key="$(printf '%s:%s' "$plugin_root/gate" release | shasum | cut -c1-16)"
gate_hash="$(cat "$real_cache/stamps/$stamp_key")"
mkdir -p "$HOME/.cache/swift-harness/bin" "$HOME/.cache/swift-harness/stamps"
cp -R "$real_cache/bin/$gate_hash" "$HOME/.cache/swift-harness/bin/"
printf '%s' "$gate_hash" >"$HOME/.cache/swift-harness/stamps/$stamp_key"
echo "gate_hash=$gate_hash" >>"$workspace/.eval/scaffold-env.txt"

cp -R "$repo_root/examples/SampleApp/." "$workspace/"
# In this repo the root .gitignore covers SampleApp; the copy needs its own.
{ cat "$repo_root/.gitignore"; echo ".eval/"; } >"$workspace/.gitignore"
git -C "$workspace" init -q -b main
git -C "$workspace" add -A
git -C "$workspace" -c user.name=eval -c user.email=eval@example.invalid commit -qm baseline
git init -q --bare "$workspace/.eval/origin.git"
git -C "$workspace" remote add origin "$workspace/.eval/origin.git"
git -C "$workspace" push -q origin main
