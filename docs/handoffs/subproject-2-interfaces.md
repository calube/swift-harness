# Sub-project 2 — interfaces note

Running record of the types, file formats and flags each merged wave introduced, for later workers.
Only the orchestrator edits this file, appending one section per wave at merge. Workers read it.

## Before wave 1: gate fix

- New module kind `test-support` (`ModuleKind.testSupport`, `ModuleRole.testSupport`). It's excluded from T1
  presence, diff coverage and the determinism lint. Rule `arch.test-support-dependency` (major): only test
  targets and other test-support modules may depend on one. `SwiftGateTestSupport` is declared with this kind.

## Wave 1

**Bootstrap**
- `BootstrapPlanner.Paths.docsIndex = "docs/index.md"`, `HarnessTemplates.docsIndex: String` (last init parameter),
  `BootstrapFiles.TemplateNames.docsIndex = "templates/docs-index.md"`. The router is created once, then left alone.
  The design and plan skills own adding rows.
- `Paths.planIndex` / `emptyPlanIndex` were removed: nothing under `.harness/plans/` is stamped any more.
- `BootstrapPlanner.gitHooks = ["pre-commit", "pre-push"]`. The `commit-msg` hook lands with `comments --commit-msg`.
- `templates/design-doc.md`: frontmatter `status` / `area` / `tier`, plus the spec §5.3 sections in order.

**Evidence records** (all in `SwiftGateDomain`)
- `Claim` (id, lane, text, citation, status) and `Citation` (kind `.file/.snapshot/.capture/.probe/.answer`, `loc`,
  `pin?`, `quote?`).
- `ClaimStatusMachine.canTransition(from:to:citationKind:)`. `ClaimJSON.encodeLine` / `decode` (JSONL).
- `Amendment` (title, at, class, fromSha, toSha, changedIds, newClaims, trigger, review?, approval?).
  `Amendment.Class` is `.amend` / `.clarify`. Also `Amendment.isValid(_:)` and `AmendmentJSON`.
- `IdKind` `.requirement/.testPlanItem/.claim` → prefixes `req-` / `test-` / `ev-`. `IdPolicy.isValid(_:kind:)`
  requires ≥3 words and rejects `-R1`-style suffixes. Also `IdPolicy.isValidADRSlug(_:)`.
- `EvidenceLayout(designDocPath:)` → `.root`, `.claimsFile`, `.amendmentsFile`, `.snapshotsDirectory`,
  `.capturesDirectory`, `.probesDirectory`.

**CLI stubs** (`gate/Sources/SwiftGateCLI/Commands/`, one owner each)
- Files: `EvidenceCheckCommand`, `EvidenceCaptureCommand`, `EvidenceFindCommand`, `ProbeCommand`,
  `DesignScopeCommand`, `DesignLintCommand`, `DesignDiffCommand`, `DesignRenderCommand`, `DocsLintCommand`,
  `ProseCommand`, `PlanClaimCommand`, `PlanReleaseCommand`, `PlanScheduleCommand`, `PlanLintCommand`,
  `ContextPackCommand`, `IndexCommand` (nested `IndexSetCommand`), `CalibrateCommand` (nested
  `CalibrateDesignCommand`).
- A stub calls `try StubCommand.notImplemented("<path>", json:)`, which exits 2 (`Verdict.blocked`). Replace the call;
  don't edit `SwiftGate.swift`.
- `evidence capture` takes its passthrough command with ArgumentParser `.remaining` (`-- <cmd>`).
- `RepositoryScriptTests` discovers `tests/*_test.mjs` automatically.
