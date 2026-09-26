# `docs-lint` self-test seeds

Each case's `docs/` subtree (and an optional root `AGENTS.md`) is staged into a throwaway repo —
`docs-lint` needs `git ls-files` for its tracked-file set, so the case's files are `git add`ed,
never committed. An optional `config.toml` fragment is appended under a fixed base
`.swiftgate.toml` for a case that needs a `[docs]` table (an anchor or a tight budget).
