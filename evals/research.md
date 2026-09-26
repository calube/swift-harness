# Research

What published eval practice says, and what this directory takes from it. Gathered 2026-09-25.
Nobody fetched the sources marked *search only*; their claims come from search snippets, so check
them before quoting.

## The 5 ideas that shape the design

1. **Measure the harness as a difference.** Run each task with the plugin on and off, same model,
   and report the gap. Then remove 1 component at a time. Vercel found a skill arm scored the same
   as no skill (53% and 53%) because the skill never loaded in 56% of cases. A plugin can look
   good in absolute terms and add nothing.
2. **Grade with code first, and prove the graders.** Hidden tests, build results and a
   deterministic checker beat a model judge. A judge counts only after it agrees with people on
   labelled cases. Every grader needs cases it must reject.
3. **Reliability is the product.** Report pass^k (all k trials pass) next to pass@1. At 75% per
   trial, pass^3 is about 42%. A harness exists to make outcomes consistent, so pass^k is the
   headline number.
4. **Read the transcripts.** Error analysis on real failures, sorted into a counted list of
   causes, decides what to fix. A task nobody passes is more often a broken task than a hard one.
5. **Isolate and pin.** Each trial starts clean. Model, harness version, machine limits and
   environment change scores by several points, so a gap under about 3 points needs its interval
   and its configuration before anyone trusts it.

## Sources and what we take

### Anthropic

- **Claude Code plugin evals** ([docs](https://code.claude.com/docs/en/plugin-evals)).
  `claude plugin eval` runs every case 3 times with the plugin and 3 without, and reports `Δ`. It
  has 6 grader types: `regex`, `tool_used`, `tool_order`, `file_exists`, and the paid `llm` and
  `baseline`. Constraints that matter here:
  - it has no custom-code grader, so a build or test result has to reach a file the `regex`
    grader reads;
  - git hooks are off during runs, so it can't test the lefthook layer;
  - the `files` target lists created files, not modified ones;
  - hook decisions don't appear in its results.

  Taken: the with and without arms, 1 outcome grader plus 1 trajectory grader per case,
  should-trigger and should-not-trigger prompts, a pinned model, a cost cap. See
  [`design.md`](design.md#runner).
- **Demystifying evals for AI agents** ([post](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents), 2026-01).
  Taken: 2 experts must reach the same verdict on a task, and each task has a reference solution.
  Balanced sets test when a behaviour should and shouldn't happen. Grade outcomes, not paths.
  Capability suites graduate into regression suites once saturated. Isolate every trial.
- **Quantifying infrastructure noise** ([post](https://www.anthropic.com/engineering/infrastructure-noise), 2026-02).
  Resource limits alone moved a benchmark 6 points. Taken: record machine limits with every run,
  classify infrastructure failures apart from agent failures, distrust gaps under 3 points.
- **Writing effective tools for agents** ([post](https://www.anthropic.com/engineering/writing-tools-for-agents), 2025-09).
  Taken: track tokens, tool calls, tool errors and wall time, not only accuracy; keep a held-out
  task set.
- **skill-creator** ([skill](https://github.com/anthropics/skills/blob/main/skills/skill-creator/SKILL.md)).
  Trigger tuning uses 8 to 10 should-trigger and 8 to 10 should-not-trigger queries, a 60/40
  train/test split, 3 runs each, and picks descriptions on the test split. Taken for
  `skill-routing`.

### LangChain

- **Evaluating Deep Agents** ([post](https://www.langchain.com/blog/evaluating-deep-agents-our-learnings), 2025-12)
  and **How we build evals for Deep Agents** ([post](https://www.langchain.com/blog/how-we-build-evals-for-deep-agents), 2026).
  About half their cases are single-step (right tool, right arguments), which are cheap. Each case
  carries its own test logic, a capability tag, and a note on what it measures. "More evals ≠
  better agents": each eval pushes behaviour, so each needs a reason. Taken: tags per case, cheap
  single-step cases for guards and routing, step and tool-call ratios against a reference path to
  catch a harness that's right but wasteful.
- **Improving Deep Agents with harness engineering** ([post](https://www.langchain.com/blog/improving-deep-agents-with-harness-engineering), 2026-02).
  Harness changes alone, same model, moved Terminal-Bench 2.0 from 52.8 to 66.5. The changes were
  a pre-completion self-check, loop detection and local context. Evidence that a harness is worth
  measuring. The Stop hook plays the role of their pre-completion check, which the `no-stop`
  ablation tests.
- **Trajectory evals** ([docs](https://docs.langchain.com/langsmith/trajectory-evals)). Match modes
  `strict`, `unordered`, `subset`, `superset`. Taken: `superset` for "the required steps happened,
  extras allowed", which fits the guards and `tdd`.
- **Agent observability powers evaluation** ([guide](https://www.langchain.com/conceptual-guides/agent-observability-powers-agent-evaluation), 2026-01).
  Turn each real failure into a permanent case. Taken: escapes from real sessions become cases.

### Vercel

- **AGENTS.md outperforms skills** ([post](https://vercel.com/blog/agents-md-outperforms-skills-in-our-agent-evals), 2026-01).
  Arms: baseline 53%, skill 53%, skill with explicit instructions 79%, an `AGENTS.md` docs index
  100%. They removed test leakage, used behaviour-based assertions, and chose APIs absent from
  training data. Taken: our `off` arm keeps `AGENTS.md`, so the plugin has to beat written rules,
  not an empty repo. TCA 1.x-only rules and `@Dependency` discipline are conventions a model won't
  follow unprompted, which makes them good targets.
- **agent-eval** ([repo](https://github.com/vercel-labs/agent-eval)) and **next-evals-oss**
  ([repo](https://github.com/vercel/next-evals-oss)). Fixture shape: a small app, `PROMPT.md`, a
  held-back test file, starter source. 24 Next.js tasks covering migrations, anti-patterns and
  security. 10 runs per task for reliability data, failures sorted into model, infrastructure and
  timeout, and a cache that skips unchanged pairs of task and config. Taken: the task layout in
  [`apps.md`](apps.md#tasks), the failure classes, the skip cache.
- **Eval-driven development** ([post](https://vercel.com/blog/eval-driven-development-build-better-ai-faster), 2024-10).
  Every new feature ships with its evals. Taken: a new skill or guard ships with its
  `skill-routing` or `guard-conformance` cases.

### Benchmarks

- **SWE-bench Verified** (OpenAI, *search only*). 3 annotators per task, and 1 flag excludes it.
  About 68% of candidates failed review for vague specs or unfair tests. A task passes only if the
  new tests pass and the old tests still pass. OpenAI later called the set contaminated and its
  tests flawed. Taken: person review of every task, old tests must stay green, keep tasks private.
- **Terminal-Bench 2.0** ([paper](https://arxiv.org/html/2601.11868v1)). Each task has an oracle
  solution that must pass and a null agent that must fail, and an exploit agent tries to game the
  tests before release. Taken: every task proves its reference passes and an empty change fails;
  1 red-team pass per new task set.
- **Aider polyglot** ([post](https://aider.chat/2024/12/21/polyglot.html)). Kept only problems few
  models solve, to spread scores between 5% and 50%. Taken: drop tasks every condition passes, since
  they can't show a difference.
- **METR task desiderata** ([page](https://taskdev.metr.org/desiderata/)). No public solutions, no
  shortcut solutions, grading robust to odd output formats.
- **τ-bench** (Sierra, *search only*). An agent above 60% pass^1 fell below 25% pass^8.

### Practitioners

- **Hamel Husain and Shreya Shankar, Evals FAQ** ([post](https://hamel.dev/blog/posts/evals-faq/)).
  Error analysis first: label about 100 traces, name failures in free text, group them, stop when
  new traces stop adding causes. Pass or fail, not a 1 to 5 scale. Validate a judge by its true
  positive and true negative rates on held-out labels. "A 100% pass rate indicates insufficient
  challenge." Taken: the loop in [`design.md`](design.md#error-analysis).
- **Eugene Yan, Product evals in 3 steps** ([post](https://eugeneyan.com/writing/product-evals/)).
  1 evaluator per dimension; report precision, recall and Cohen's κ; 200 labels give about ±2.4%.
- **Shankar et al., Who Validates the Validators?** ([paper](https://arxiv.org/abs/2404.12272),
  *search only*). Criteria drift: people can't fix the criteria until they've graded outputs. Taken:
  we revise rubrics after the first labelling pass, then recheck the judge.

### Harness as a variable

- **The Scaffold Effect** ([paper](https://arxiv.org/abs/2607.22585)). Same model, different
  harnesses: pass rates within 8 points, tokens per solved task up to 40 times apart. Taken: report
  tokens per solved task. *Check this citation: the listed date doesn't match its arXiv id.*
- **Noise Floor Audit** ([paper](https://arxiv.org/abs/2608.22331)). Rewording a prompt without
  changing its meaning caused far more variance than rerunning it. Taken: each `task-lift` and
  `skill-routing` prompt gets 2 or 3 paraphrases.

### Swift and iOS

- **SwiftEval** ([paper](https://arxiv.org/abs/2505.24324)). Swift sections of translated
  benchmarks have serious flaws; scores drop on Swift-specific features. Taken: write Swift tasks
  by hand.
- **Cocoa with Love, LLMs 12 months later** ([post](https://www.cocoawithlove.com/blog/llms-twelve-months-later.html)).
  Common model mistakes in SwiftUI: missing imports, outdated availability checks, no async/await,
  Swift 6 ignored, `Timer` where `Task.sleep` fits. Taken: seeds and temptation tasks.
- **Xcode 27 agent skills** (a secondary write-up, not Apple's docs). Apple ships guidance skills
  such as `swiftui-specialist` with no verification step. Taken: a candidate comparison arm once
  confirmed from Apple's own docs.
- No public benchmark for TCA or for Swift agents working with Xcode in the loop turned up. These
  evals may be the first.

## Where the sources disagree with the first draft

The first draft of these docs predated the research. The research changed it in these places:

- `claude plugin eval` can't run git hooks, so the lefthook layer needs its own scripted cases in
  `guard-conformance`.
- `task-lift` adds a null run and an oracle run per task, and drops tasks every condition passes.
- Prompts get paraphrases, and results carry tokens per solved task and a failure class.
- `skill-routing` tunes descriptions on a train split and reports the test split.

## Evaluated and not adopted yet

- **TypeSafe Jev** ([Langfuse post](https://langfuse.com/blog/2026-09-18-using-typesafes-jev-for-evals), 2026-09-18;
  [TypeSafe announcement](https://typesafe.ai/blog/introducing-system-one-models-and-jev)). A
  judge model, not an eval framework. It answers typed choice, score and yes/no questions with
  probabilities, and writes no text. Langfuse reports 91.5% agreement with Claude Fable 5.1 at a
  small fraction of its cost. It gives no reason with its verdict, can't abstain, and loses
  accuracy on long context. It sits behind an early-access waitlist, with access through
  OpenRouter and the Vercel AI Gateway. [`design.md`](design.md#judge-model-candidates) has the
  trial we'd run before using it.
