# `PLAN.md` shape

A brownfield run's plan is 1 live file, `<plan-dir>/PLAN.md`. `swiftgate plan import <slug>` turns
it into the executor's `ledger.json`, and carries each task's goal, `Why`, `Scope`, `Acceptance` and
`Out of scope` into `plan.json` as the brief the run viewer shows. Anything the importer can't read
fails the import and names the task and the line.

## Sections

- `# <title>`: 1 line naming the change.
- `## Areas`: 1 bullet per touched area: its name, its warm test time from the warm-up, and
  `build-only` when that time exceeds `slice_budget_s`, or `unknown` while the warm-up hasn't
  reached it. The importer ignores this section; the report and the workers read it.
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
| `- Writes:` | its write set: repository-relative paths, comma-separated; a path ending in `/` is a prefix | yes |
| `- Does:` | anything a worker needs that the bullets above don't say | no |
| `- Tests:` | the test files it adds or changes | no |

`Gate` is `slice` for every task: `merge` and `final` run on the plan branch, not per task. Leave
`Model` out, so the brownfield preset's pinned worker model applies. A path in `Writes` never
starts with `/` and never contains `..`.

## Example

```markdown
# Export the report as CSV

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
- Writes: api/export/handler/, api/tests/export/
```

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
