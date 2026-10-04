---
name: bootstrap
description: This skill should be used to stamp or upgrade the swift-harness layer in a Swift/iOS app repository with `swiftgate bootstrap` (AGENTS.md router, .swiftgate.toml inferred from the repo, format/lint configs, lefthook git hooks, .gitignore entries, the plan index, the ~/.local/bin/swiftgate link). Shows the diff and asks before writing. In a repository the harness doesn't own, its brownfield branch runs `swiftgate discover --apply`, which writes only under the git dir. Use when the user says "bootstrap", "set up swift-harness", "install the harness in this repo", "upgrade the harness files", "add the git hooks", or when `swiftgate doctor` reports the shim missing or stale, or a repo has no .swiftgate.toml.
---

# Bootstrap

Stamps the per-app layer from the plugin's `templates/`. `swiftgate bootstrap` decides everything;
this skill only previews, asks, applies, and follows up. Never hand-write these files instead.

`SG="${CLAUDE_PLUGIN_ROOT}/bin/swiftgate"` below. Always call bootstrap through this path: the shim
tells the binary where the templates are.

A repository the harness doesn't own takes the [brownfield branch](#brownfield-a-repository-the-harness-doesnt-own)
instead of steps 1 to 4: the user asks for the brownfield profile, says the repository's files
must stay as they are, or the git common dir already holds `swift-harness/config.toml`.

## 1. Preview (writes nothing)

1. Run from the root of the Swift project (the directory that will hold `.swiftgate.toml`), usually
   the git toplevel. If the project sits inside a larger repository, run it from the project
   directory; bootstrap then leaves `lefthook.yml` alone, says how to wire the toplevel one, and
   does not run `lefthook install`.
2. Run `"$SG" bootstrap`. When the user says what the repository is optimised for, such as
   interview practice, run `"$SG" bootstrap --profile <name>` instead, where `<name>` is a
   `[build.presets.<name>]` table the template stamps (`default` or `interview`), and keep the
   flag for the apply. The profile only picks the preset `/swift-harness:build` and
   `/swift-harness:ship` use without `--preset`. The first call after a plugin update builds swiftgate, which can take a
   few minutes; let it finish in the foreground. Exit status 2 here means BLOCKED before any
   preview (templates not found, or not run through the plugin shim): report it and stop.
3. Read the output. It starts with `bootstrap: N to write, …` and then has:
   - a unified diff per file it would create or change,
   - `CLAUDE.md -> AGENTS.md (new symlink)` when the link is missing,
   - `Left alone:` files it will not touch, each with the reason,
   - `Outside the repository:` the registry entry, the `~/.local/bin/swiftgate` link, and
     `lefthook install`,
   - `Notes:` config values it could not infer (`SET-ME`), a missing lefthook, no git repository,
     and home-directory problems it will not fix (an invalid registry, a regular file at
     `~/.local/bin/swiftgate`).
4. If it ends with `Nothing to do.`, tell the user the repository is current and stop.

## 2. Ask

Summarize the preview for the user in a few lines: which files are created or changed, what stays
alone, and whatever is listed under `Outside the repository:` (zero to three items). Don't paste whole created files; `.swift-format`
is the toolchain's default configuration and `AGENTS.md` gains a managed block between
`<!-- swift-harness:begin -->` markers, so the team's own text there is kept.

Then ask with `AskUserQuestion` (one question, header "Bootstrap"):

- **Apply** — write everything shown.
- **Show the full diff** — print the dry-run output, then ask again.
- **Cancel** — write nothing.

Never run `--apply` without an explicit **Apply**.

## 3. Apply

1. Run `"$SG" bootstrap --apply`, or `"$SG" bootstrap --apply --profile <name>` when the preview
   used one. It prints `bootstrap: applied N change(s)` and one line per change.
2. Exit status 2 means BLOCKED: a template is missing, a write failed, or `lefthook install`
   failed. Output starting `bootstrap: applied partly, then failed:` lists what was already
   written. That is the installation or the file system, not the code: report both and stop;
   don't retry with hand-made files.
3. Run `"$SG" bootstrap` once more. It must end with `Nothing to do.`; anything else is a bug to
   report, not something to paper over.

## 4. Follow up

- **`SET-ME` in `.swiftgate.toml`.** Bootstrap writes the config once and never rewrites it. For
  each unresolved value in `Notes:`, ask the user with `AskUserQuestion` (batch them into one call),
  then edit `.swiftgate.toml` by hand.
- **Config advice.** For an existing config, `Left alone: .swiftgate.toml: … consider editing`
  lists what breaks a run (Xcode pin, uncovered packages, app_scheme mismatch, a simulator that isn't installed, or
  `[docs] managed_files` missing the router or `AGENTS.md` — an upgraded repo whose config predates that key
  otherwise leaves docs-lint, and so pre-push, red with no visible cause). Offer the edit; don't make it silently.
- **CLAUDE.md is a real file.** Offer to move its content into `AGENTS.md` outside the managed
  block, delete `CLAUDE.md`, and re-run bootstrap so it becomes the link.
- **lefthook or swiftlint missing.** Tell the user to install it (for example with Homebrew), then
  re-run this skill. swiftlint is optional and style-only.
- **Verify.** Run `"$SG" doctor`. GREEN means the machine matches the config; BLOCKED names what to
  fix in the environment (Xcode pin, simulator runtime, disk, shim).
- **Module kinds.** Run `"$SG" arch`. It fails any non-TCA Core without a `[[modules]]` entry
  (`arch.undeclared-kind`); if it reports that, hand off to `/swift-harness:architecture`.

Report in two or three lines: what was written, anything left for the user, and the doctor
verdict. Committing the stamped files is the user's call.

## Brownfield: a repository the harness doesn't own

Nothing is stamped into the tree: no `.swiftgate.toml`, no `AGENTS.md` block, no git hooks, no
`.gitignore` line. The config, the hook settings and every run's state live under
`$(git rev-parse --git-common-dir)/swift-harness/`, which git never sees.

1. From the repository's toplevel, run `"$SG" discover --apply`. It proposes each area's
   language, root and commands from the tracked files in a few seconds, writes the config and
   `settings.json`, and prints the proposal: 1 row per area and step with its command and whether
   it was `found`, `guessed` or `missing`. Discovery needs no confirmation; a wrong guess is fixed
   later by `"$SG" discover --apply --set <area>.<step>=<command>`, or dropped by
   `"$SG" discover --apply --drop <area>.<step> --reason "<why>"`.
2. Exit status 2 means BLOCKED (not a git repository, or the config couldn't be written): report
   the message and stop.
3. `git status --porcelain` must print what it printed before step 1. Anything new is a bug to
   report.

Report in 2 or 3 lines: the areas found, the steps guessed or missing, and the next step: hand
a spec to `swiftgate run <spec.md>`, which plans and builds it on its own branch.
