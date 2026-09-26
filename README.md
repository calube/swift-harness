# swift-harness

A Claude Code plugin that holds SwiftUI iOS work to a consistent bar: codified standards, a testing
playbook, `swiftgate` (the single gate tool every hook, skill, and git hook calls), and review and
validation workflows.

- Docs: start at [`docs/index.md`](docs/index.md)
- Design: `docs/designs/2026-09-24-swift-harness-foundation-design.md`
- Plan: `docs/plans/2026-09-24-foundation-plan.md`

## Install

The repository is its own plugin marketplace (`.claude-plugin/marketplace.json`). Register it once
per machine, then enable the plugin only in the iOS repositories that use it, so its hooks never
load anywhere else:

```bash
claude plugin marketplace add calube/swift-harness      # or a local checkout: ./path/to/swift-harness
cd /path/to/your-ios-app
claude plugin install swift-harness@swift-harness --scope project   # or --scope local
```

Then run `/swift-harness:bootstrap` in a session there. It runs `swiftgate bootstrap` (dry run,
then `--apply`), which writes `.swiftgate.toml`, `AGENTS.md`, the git hooks, and links
`~/.local/bin/swiftgate`.

`marketplace add` records the marketplace in your user settings but enables nothing. `--scope
project` writes the plugin to the repository's `.claude/settings.json`, which you commit:

```json
{
  "enabledPlugins": { "swift-harness@swift-harness": true }
}
```

`--scope local` writes the same key to `.claude/settings.local.json` instead, for just you.
Avoid the default user scope: it loads the hooks in every session on the machine. They no-op
outside a repository with `.swiftgate.toml`, but each still spawns a process per tool call.

To try a checkout without installing anything, pass it for one session:
`claude --plugin-dir /path/to/swift-harness`.

Sources: https://code.claude.com/docs/en/plugin-marketplaces,
https://code.claude.com/docs/en/plugins/install (install scopes),
https://code.claude.com/docs/en/settings-reference (`enabledPlugins`).

## Skills

Each runs as `/swift-harness:<name>`.

| Skill | Use it to |
|---|---|
| `bootstrap` | stamp or upgrade the harness in an iOS repository |
| `architecture` | pick a new module's kind and scaffold its packages |
| `design` | frame, research, draft, review, publish and amend a design before any code |
| `plan` | turn an approved design into a build plan of sized, scheduled tasks |
| `prose` | write docs that pass the plain-English rules `swiftgate prose` checks |
| `tdd` | write a failing test first, then make it pass |
| `test-gate` | run the pre-ready gate and judge new tests for slop |
| `review` | run the multi-agent code review on a Swift change |
| `comment-audit` | judge each comment a change adds: keep, trim or cut |
| `validate` | produce ready-for-review evidence and a PR body block |
| `status` | list active plans across this machine's bootstrapped repositories |

## Contributing

`cd gate && swift build && swift test && swift format lint --strict -r Sources Tests Package.swift`.
`swift test` also runs `tests/review_workflow_test.mjs` (needs `node`) and `tests/shim_test.sh`;
each is reported as skipped when its interpreter is missing from `PATH`.
`claude plugin validate .` checks the marketplace and plugin manifests.

Status: Foundation complete; live-session results in `docs/e2e-report.md`.
