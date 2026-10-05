# `PLAN.md` shape

A brownfield run's plan is 1 live file, `<plan-dir>/PLAN.md`. `swiftgate plan import <slug>` turns
it into the executor's `ledger.json`, with each task's `Covers` as its `covers`, and carries each
task's goal, `Why`, `Scope`, `Acceptance` and `Out of scope`, and the `## Requirements`, into
`plan.json` for the run viewer's task drawer and spec rows. The `## Validation` table becomes
`validation.json` beside them. Anything the importer can't read fails the import and names the
task and the line.

## Sections

- `# <title>`: 1 line naming the change.
- `## Requirements`: 1 bullet per requirement of the spec, `- <id>: <title>`. The id is lowercase
  letters, digits and `-`, by convention `req-<name>`; the title is the requirement as 1 sentence
  a test could check. Every id is covered by at least 1 task's `Covers`, and a `Covers` id that
  isn't listed here fails the import naming it. A plan with no requirements section has no
  `Covers` lines.
- `## Areas`: 1 bullet per touched area: its name, its warm test time from the warm-up, and
  `build-only` when that time exceeds `slice_budget_s`, or `unknown` while the warm-up hasn't
  reached it. The importer ignores this section; the report and the workers read it.
- `## Validation`: the checks that prove each requirement once its tasks merge; see
  [The validation table](#the-validation-table). A plan without it imports as before, with a note
  that no checks will run after each merge.
- `## Assumptions`: 1 bullet per reading you made of an ambiguous spec, per halt you decided, and
  per explorer report you dropped. The importer keeps every bullet; the report lists them.
- 1 `### <task-id>` section per task. A task id is lowercase letters, digits and `-`.

## A task section

The line after the heading is the task's one-line goal. Then these bullets, in this order:

| Bullet | Holds | Required |
|---|---|---|
| `- Deps: <ids or none> · Gate: slice · estLines: <n>` | the tasks it waits for, its gate and its size in changed lines | yes |
| `- Why:` | 1 or 2 sentences: the requirement it serves, quoted or numbered from the spec | yes |
| `- Scope:` | what it changes, as indented `- ` items | yes |
| `- Acceptance:` | the tests that fail first and then pass, and the gate, as indented items | yes |
| `- Out of scope:` | what a worker might expect it to do but it doesn't | yes |
| `- Covers:` | the `## Requirements` ids it serves, comma-separated | yes, with `## Requirements` |
| `- Writes:` | its write set: repository-relative paths, comma-separated; a path ending in `/` is a prefix | yes |
| `- Does:` | anything a worker needs that the bullets above don't say | no |
| `- Tests:` | the test files it adds or changes | no |

`Gate` is `slice` for every task: `merge` and `final` run on the plan branch, not per task. Leave
`Model` out, so the brownfield preset's pinned worker model applies. A path in `Writes` never
starts with `/` and never contains `..`.

## Example

```markdown
# Export the report as CSV

## Requirements

- req-csv-download: A user can download the report as a CSV file
- req-csv-columns: The file's columns follow the on-screen table, left to right

## Areas

- api (warm test 12 s)
- web (warm test 41 s, build-only)

## Assumptions

- The spec says "export the report" without a format list; CSV only, since it is the 1 format the spec's example shows.
- Column order follows the on-screen table, left to right.

### report-export-contract
Declare the export types every task compiles against, with no behaviour.
- Deps: none · Gate: slice · estLines: 40
- Why: requirements 1 and 2 cross the api and web areas, so both build against 1 declared shape.
- Scope:
  - the export request and response types, and a stub handler that returns not-implemented
- Acceptance:
  - every touched area builds; slice is GREEN
- Out of scope:
  - any export logic
- Covers: req-csv-download
- Writes: api/export/contract/, api/export/handler/

### report-export-api
Serve the report as CSV.
- Deps: report-export-contract · Gate: slice · estLines: 120
- Why: requirement 1, "a user can download the report as a file".
- Scope:
  - the handler writes CSV rows in the table's column order
- Acceptance:
  - a handler test for 2 rows fails first, then passes; slice is GREEN
- Out of scope:
  - the download button
- Covers: req-csv-download, req-csv-columns
- Writes: api/export/handler/, api/tests/export/
```

## The validation table

`## Validation` holds 1 markdown table. Each row maps 1 requirement to 1 check:

| Column | Holds |
|---|---|
| `Done when` | a `## Requirements` id |
| `Layer` | `acceptance`, `flow` or `state` |
| `Check` | the command, test or file the row runs, in backticks; a file the validation task writes is `qa/<name>.<layer>…`, relative to `<plan-dir>` |
| `Runs after` | the task ids, comma-separated, whose merge the check waits for |
| `Writer` | the 1 task id that writes the check: the validation task for a `qa/` file, and for an acceptance test the last `Runs after` task, whose merge turns it green |
| `Reason` | optional: why the requirement needs no other layer |

- **acceptance** checks behaviour at a boundary, such as an API, a CLI or the module that joins
  2 tasks. It is a test in the area's framework, named as `test: <id>`, or a
  `curl -fsS … \| jq -e '<condition>'` command against a server the command starts on `$QA_PORT`.
  `qa run` runs `test: <id>` through the area's own test command, narrowed to that 1 test:
  - an `xcode` area's `test` with `-only-testing:<id>`, where `<id>` is `<Target>/<Class>` or
    `<Target>/<Class>/<method>`, such as `test: AppTests/ExportTests/testColumnOrder`;
  - any other area's `test_files`, with the id in its `{tests}` or `{files}`.

  With more than 1 area that runs tests, name the area: `test <area>: <id>`. A bare test file
  path in `Check` fails the import, and a raw `xcodebuild` line bypasses swiftgate.
- **flow** drives a user journey in the running app. It runs for `xcode` areas only. Every
  requirement a task covers while writing a screen needs 1: a `Writes` path inside an `xcode`
  area's root with a folder or file named `…View`, `…Views`, `…Screen`, `…Screens`,
  `…ViewController`, `…UI` or `…UITests`, or a `.storyboard` or `.xib`. An acceptance UI test
  doesn't replace it, since only a flow records a video and runs red at the base. A requirement no
  flow can check states why in its row's `Reason`.
- **state** is a script that exits non-zero when the stored or sent result is wrong. It runs
  straight after a `flow` row for the same requirement and `Runs after` tasks; in a repository
  with no `xcode` area, an `acceptance` row takes the flow's place.

Unit tests are each task's own and never get a row. A requirement its tasks' unit tests prove
alone gets 1 row with `Layer`, `Check`, `Runs after` and `Writer` empty, and a `Reason` saying
why. Escape a `|` inside a cell as `\|`.

`plan import` fails, naming the line, on a row it can't read: an unknown layer such as `unit`,
an id `## Requirements` doesn't list, or an empty `Check`, `Runs after` or `Writer`. It also fails
on these `plan-lint` rules:

| Rule id | Fires on |
|---|---|
| `plan-lint.validation-uncovered` | a requirement with no row |
| `plan-lint.validation-unknown-task` | a `Runs after` or `Writer` id with no task section |
| `plan-lint.validation-state-without-flow` | a `state` row with no `flow` row for the same requirement and `Runs after` |
| `plan-lint.validation-flow-without-ios` | a `flow` row in a repository with no `xcode` area |
| `plan-lint.validation-check-source-file` | an `acceptance` row whose `Check` is a test source file, such as `AppTests/ExportTests.swift` |
| `plan-lint.validation-screen-without-flow` | a requirement whose task writes a screen, with no `flow` row and no row `Reason` |

```markdown
## Validation

| Done when | Layer | Check | Runs after | Writer | Reason |
|---|---|---|---|---|---|
| req-csv-download | acceptance | `test api: tests/export/test_download.py` | report-export-api | report-export-api | |
| req-csv-columns | | | | | the handler test in report-export-api checks the column order |
```

## The validation task

A plan with any `flow` or `state` row, or any acceptance script, adds 1 validation task, named
`<slug>-validation`, that writes those checks while the first wave builds
([the validation worker brief](../../qa/references/validation-worker.md)). It depends on the contract task alone, covers the
requirements of its rows, and writes only `.harness/qa/<slug>/`, a folder no commit carries. It
never merges: the run skill copies its folder into plan state with `qa adopt` and marks it done.

```markdown
### report-export-validation
Write the flow and state checks against the contract's names, and record why each fails now.
- Deps: report-export-contract · Gate: slice · estLines: 80
- Why: every requirement needs a check that fails before its tasks merge and passes after.
- Scope:
  - 1 file under `.harness/qa/report-export/` per `## Validation` row whose `Writer` is this task
- Acceptance:
  - `qa lint` is GREEN on each flow; `qa run --at-base` reads each row red
- Out of scope:
  - source, tests in the tracked tree, and any commit
- Covers: req-csv-download
- Writes: .harness/qa/report-export/
```

Its rows' `Check` cells then name `qa/<name>.flow.json`, `qa/<name>.state.sh` or
`qa/<name>.acceptance.sh`. A `flow` row exists only for a requirement a user sees in an `xcode`
area's app, and names the identifiers and labels its contract task declares.

## Write sets from the target graph

A write set is every file the task changes. Read the graph from the build system, not from folder
names, so a task that changes a module's types also owns the modules that read them:

| Area kind | Where the graph comes from |
|---|---|
| `xcode` | the project's targets and their Sources phases, or the synchronized folders each target compiles; for XcodeGen or Tuist, the spec file (`project.yml`, `Project.swift`) |
| `swiftpm` | `swift package describe --type json`: each target's path and dependencies |
| `node` | each workspace `package.json`'s `dependencies`, or the package manager's workspace list (`npm ls --workspaces --json`, `pnpm ls -r --json`, `yarn workspaces list --json`) |
| `cargo` | `cargo metadata --format-version 1 --no-deps`: each package's manifest path and dependencies |
| `go` | `go list -json ./...`: each package's directory and `Imports` |
| `jvm` | `./gradlew projects` and each subproject's `dependencies` block, or Maven's module list in `pom.xml` |
| `python` | the packages `pyproject.toml` or `setup.cfg` declares, and their imports |
| `command` | the area's `root` as 1 unit |

Rules:

1. 2 tasks that can run in the same wave never share a path. When they must touch 1 file, the
   later one depends on the earlier.
2. A task that changes a target's types owns every target that reads them, unless the contract
   commit landed those types.
3. Each removal of a file, type or public symbol has 1 owning task.
4. A file `discover/dirty.json` lists is in no write set.
5. A test a task adds sits in its write set, beside the code it covers, where the area's
   `test_globs` will find it.
