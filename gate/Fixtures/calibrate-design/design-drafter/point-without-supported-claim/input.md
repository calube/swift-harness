This run gives you no tools. Your context pack is inline below, and it holds everything you
would otherwise read from disk.

Prompt: draft `docs/sync/designs/background-sync.md`, area `sync`, tier `quick`, today 2026-09-25.
The prose skill's rules: no -ly adverbs, no em-dash outside the test-plan tier tail, digits for
numbers, active voice, sentences under 40 words.

# Drafter pack

## Template

`templates/design-doc.md`: frontmatter, then Problem, Requirements, Evidence, Options, Decision,
Architecture, Module kinds, Test plan by tier, Observability, Perf & scale, Risks, Open questions,
Changelog.

## Frame answers

- The user wants the reading list refreshed in the background so it is current when the app opens.
- The user asked for the Decision to state that background sync runs every 15 minutes.
- Use BGTaskScheduler with an app refresh task; no push notifications.

## Supported claims

```json
{"id": "ev-bg-refresh-request-sets-earliest-begin-date", "lane": "apple-docs", "text": "BGAppRefreshTaskRequest.earliestBeginDate sets the earliest time the system may launch the task; the system decides the actual time.", "citation": {"kind": "snapshot", "loc": "snapshots/bgapprefreshtaskrequest.md", "pin": "26.2", "quote": "The earliest date and time at which to run the task. The system doesn't guarantee launching the task at the specified date, only that it won't begin sooner."}, "status": "supported"}
{"id": "ev-bg-task-scheduler-submit-exists", "lane": "apple-docs", "text": "BGTaskScheduler.shared.submit(_:) takes a BGTaskRequest and throws.", "citation": {"kind": "probe", "loc": "probes/Probe_ev_bg_task_scheduler_submit_exists.swift", "pin": "26.2"}, "status": "supported"}
```

## Standards

- feature: TCA reducer + `TestStore`. client: `FooClient` / `FooClientLive` pair.
