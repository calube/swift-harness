# The spec page

A sprint builds from 1 Markdown page, not a design doc. The session writes it from the spec file
before `swiftgate sprint start`, and every later step reads it: the surface holds what it lists,
and the slices run in its order.

## Where it lives

`<plans>/sprints/<slug>.md`, where `<plans>` is
`$(git rev-parse --path-format=absolute --git-common-dir)/swift-harness/plans`. It sits in plan
state, shared by every worktree and never committed. Pass its absolute path to
`sprint start --spec-page`.

## Format

At most 400 words. These sections, in this order:

```markdown
# <title>

Spec: <spec-file>

## Goal
<1 to 3 sentences: what a user can do when this is done>

## Modules
| Module | Kind | Owns | Depends on |
|---|---|---|---|
| <name> | <module kind from standards.md> | <what it holds> | <modules or none> |

## Surface
- `<Type or screen>`: <its new cases, properties, methods or State/Action members>

## Slices
1. <what the slice adds>. Test: `<test name>`: <the observable result it asserts>. Spec: "<the acceptance line quoted from the spec file>" | none
2. …

## Out of scope
- <what the spec file leaves out, or what this sprint defers>
```

## Rules

- **Modules.** Use the module kinds and boundaries in `standards.md`. Name only modules this sprint
  creates or changes.
- **Surface.** Every type, case, property, method signature and screen a slice's test needs. The
  surface commit holds this list and nothing else, as stubs.
- **Slices.** Each slice has 1 acceptance test, no more, and each test observes behaviour a user or
  caller can see. Order slices so each builds on the ones before it. The slice count here is the
  `--slices` value.
- **Spec.** Quote the spec file's own acceptance line, word for word, when the slice's test
  checks it. Write `none` when the spec file lists no such line. A paraphrase counts as `none`.
- **Confirm.** When no slice says `Spec: none`, the page goes on without asking. Otherwise the
  session asks the user once, as the skill's spec page step says.
