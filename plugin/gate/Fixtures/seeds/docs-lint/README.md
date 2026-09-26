# `docs-lint` self-test seeds

Each case's `docs/` subtree (and an optional root `AGENTS.md`) is staged into a throwaway repo —
`docs-lint` needs `git ls-files` for its tracked-file set, so the case's files are `git add`ed,
never committed. An optional `config.toml` fragment is appended under a fixed base
`.swiftgate.toml` for a case that needs a `[docs]` table (an anchor or a tight budget).

Every case links its docs from a `docs/index.md` router listed in `managed_files`, so only the
rule a case exists to prove fires. `unreachable-doc-no-router/` has no router at all: each doc
under `docs/` is unreachable.
