// Pure functions over a RunView: laying out the timeline, and formatting.
// Loaded as a classic script so the report can inline it; it publishes one global.
(function (root) {
  const ms = (iso) => (iso == null ? null : Date.parse(iso));

  // The run's last event: what an open span is cut at in the report.
  function lastEventMs(view) {
    const times = [ms(view.run.startedAt), ms(view.run.endedAt)];
    (view.spans || []).forEach((s) => times.push(ms(s.start), ms(s.end)));
    (view.halts || []).forEach((h) => times.push(ms(h.at)));
    (view.tasks || []).forEach((t) => times.push(ms(t.createdAt), ms(t.mergedAt)));
    return Math.max.apply(null, times.filter((t) => t != null && !Number.isNaN(t)));
  }

  function spanLabel(s) {
    if (s.phase === "run") return "build run";
    if (s.phase === "task") return s.task || "task";
    if (s.phase === "gate") return "gate";
    return s.phase.replace(/[-.]/g, " ");
  }

  // Spans in minutes from the run's start, with open spans cut at the run's last event.
  function normalize(view, nowMs) {
    const t0 = ms(view.run.startedAt);
    const cut = nowMs != null ? nowMs : lastEventMs(view);
    const toMin = (t) => (t - t0) / 60000;
    const gateBy = {};
    (view.gates || []).forEach((g) => { gateBy[g.runId] = g; });
    const spans = (view.spans || []).map((s) => {
      const open = s.end == null;
      const g = s.gateRun && gateBy[s.gateRun];
      let label = spanLabel(s);
      if (s.phase === "gate" && g) label = "gate " + gateTier(g.command);
      return Object.assign({}, s, { start: toMin(ms(s.start)), end: toMin(open ? cut : ms(s.end)), open, label });
    });
    return { spans, wall: Math.max(0, toMin(cut)), t0 };
  }

  function gateTier(command) {
    const m = /--tier\s+(\S+)/.exec(command || "");
    return m ? m[1] : command || "";
  }

  // Greedy first-fit: each span takes the first row it doesn't overlap.
  function pack(spans) {
    const rows = [];
    spans.slice().sort((a, b) => a.start - b.start).forEach((s) => {
      const row = rows.find((r) => r[r.length - 1].end <= s.start);
      if (row) row.push(s); else rows.push([s]);
    });
    return rows;
  }

  // Timeline rows. A task's (or the final phase's) descendants share rows under it, so a worker's
  // whole story reads left to right; its gate runs add 1 row per tier, steps from the gate record.
  function lanes(spans, gates) {
    const byId = {};
    const kids = {};
    spans.forEach((s) => { byId[s.id] = s; });
    spans.forEach((s) => {
      const p = s.parent != null && byId[s.parent] ? s.parent : null;
      (kids[p] = kids[p] || []).push(s);
    });
    Object.keys(kids).forEach((k) => kids[k].sort((a, b) => a.start - b.start));
    const gateBy = {};
    (gates || []).forEach((g) => { gateBy[g.runId] = g; });
    const descendants = (s) => (kids[s.id] || []).reduce((acc, c) => acc.concat([c], descendants(c)), []);
    const rows = [];

    function gateRows(gs, depth) {
      const g = gateBy[gs.gateRun];
      if (!g || !g.steps || !g.steps.length) return;
      const minutes = g.ms / 60000;
      const factor = minutes > 0 ? (gs.end - gs.start) / minutes : 0;
      // A GREEN run's red steps are the ones its baseline excused.
      const excused = spans.some((x) => x.phase === "step" && x.gateRun === g.runId && x.baseline);
      const tiers = [];
      g.steps.forEach((st) => { if (tiers.indexOf(st.tier) < 0) tiers.push(st.tier); });
      tiers.forEach((tier) => {
        let cursor = 0;
        const steps = g.steps.filter((st) => st.tier === tier).map((st) => {
          // A step with no start offset is laid end to end after the last and marked approximate.
          const approximate = st.startMs == null;
          const startMs = approximate ? cursor : st.startMs;
          cursor = startMs + st.ms;
          return {
            id: gs.id + ":" + tier + ":" + st.step, parent: gs.id, phase: "step", label: st.step,
            start: gs.start + (startMs / 60000) * factor, end: gs.start + ((startMs + st.ms) / 60000) * factor,
            outcome: st.verdict === "RED" ? "red" : "ok", gateRun: g.runId, task: gs.task, ms: st.ms, tier, approximate,
            baseline: excused && st.verdict === "RED"
          };
        });
        rows.push({ depth, label: tier + " · " + (g.verdict === "RED" ? "RED run" : "run") + " " + shortRun(g.runId), spans: steps });
      });
    }

    function walk(s, depth) {
      rows.push({ depth, spans: [s], label: s.label, isTask: s.phase === "task" });
      if (s.phase === "task" || s.phase === "final") {
        const all = descendants(s);
        pack(all).forEach((r, i) => rows.push({ depth: depth + 1, spans: r, label: i === 0 ? (s.phase === "task" ? "stages" : "gate") : "" }));
        all.filter((c) => c.phase === "gate" && c.gateRun).forEach((gs) => gateRows(gs, depth + 2));
      } else {
        (kids[s.id] || []).forEach((c) => walk(c, depth + 1));
      }
    }
    (kids.null || []).forEach((s) => walk(s, 0));
    return rows;
  }

  const ZOOMS = [1, 2, 4];
  const scale = (zoom, width) => width * (ZOOMS.indexOf(zoom) >= 0 ? zoom : 1);
  // Rough width of a bar label at 11px plus its 12px of padding.
  const labelFits = (text, px) => px >= String(text).length * 6.3 + 12;

  const sum = (t) => t.input + t.output + t.cacheRead + t.cacheWrite;
  const fmtTok = (n) => (n >= 1e6 ? (n / 1e6).toFixed(2) + "M" : Math.round(n / 1e3) + "k");
  const fmtTokens = (t) => (t == null ? "pending" : fmtTok(sum(t)));
  // US dollars to 2 places; `null` when no cost is known, which a page shows as no figure.
  const fmtUSD = (usd) => null;
  // The header's cost stat: the run's dollars and what they leave out.
  const costStat = (cost) => null;
  const fmtMin = (m) => {
    const s = Math.round(m * 60);
    return s >= 60 ? Math.floor(s / 60) + "m " + String(s % 60).padStart(2, "0") + "s" : s + "s";
  };
  const fmtMs = (n) => fmtMin(n / 60000);
  const shortRun = (id) => (id && id.length > 15 ? id.slice(9, 15) + "…" + id.slice(-4) : String(id));
  const durationText = (s) => (s.open ? "never ended" : s.ms != null ? fmtMs(s.ms) : fmtMin(s.end - s.start));

  function blocks(view, id) {
    return (view.tasks || []).filter((t) => (t.deps || []).indexOf(id) >= 0).map((t) => t.id);
  }

  // A task's wave counts only task deps; a dep cycle stops at the task already being visited.
  function waveOf(view, id) {
    const byId = {};
    (view.tasks || []).forEach((t) => { byId[t.id] = t; });
    const memo = {};
    const visit = (tid, seen) => {
      if (memo[tid]) return memo[tid];
      const deps = (byId[tid] ? byId[tid].deps || [] : []).filter((d) => byId[d] && seen.indexOf(d) < 0);
      memo[tid] = deps.length ? 1 + Math.max.apply(null, deps.map((d) => visit(d, seen.concat([tid])))) : 1;
      return memo[tid];
    };
    return visit(id, []);
  }

  // A task's events in time order: created, worker and fix starts, gate verdicts, review, halts
  // and merge. `at` is milliseconds since the epoch.
  function activity(view, id) {
    const t = (view.tasks || []).find((x) => x.id === id);
    if (!t) return [];
    const events = [];
    if (t.createdAt) events.push({ at: ms(t.createdAt), kind: "created", text: "Created", c: "--muted" });
    const gateBy = {};
    (view.gates || []).forEach((g) => { gateBy[g.runId] = g; });
    const gatesSeen = {};
    (view.spans || []).filter((s) => s.task === id).forEach((s) => {
      if (s.phase === "worker") events.push({ at: ms(s.start), kind: "worker", text: "Worker started", sub: (t.model || "") + " build worker", c: "--bar-worker" });
      else if (s.phase === "fix") events.push({ at: ms(s.start), kind: "fix", text: "Fix started", sub: s.tools ? s.tools.files.length + " files touched" : "", c: "--warn" });
      else if (s.phase === "review") events.push({ at: ms(s.start), kind: "review", text: "Review started", c: "--bar-review" });
      else if (s.phase === "verify") events.push({ at: ms(s.start), kind: "verify", text: "Verify started", c: "--warn" });
      else if (s.phase === "gate" && s.gateRun) {
        gatesSeen[s.gateRun] = true;
        const g = gateBy[s.gateRun];
        const verdict = g ? g.verdict : s.outcome === "red" ? "RED" : "GREEN";
        const sub = (g ? gateTier(g.command) + " gate · " : "") + "run " + shortRun(s.gateRun);
        if (s.end == null) events.push({ at: ms(s.start), kind: "gate", text: "Gate running", sub, c: "--warn" });
        else events.push({ at: ms(s.end), kind: "gate", text: "Gate " + verdict, codes: g ? (g.failure && g.failure.findings.length ? g.failure.findings.map((x) => x.rule) : Object.keys(g.ruleCounts || {})) : [], sub, c: verdict === "RED" ? "--bad" : "--ok" });
      }
    });
    (view.halts || []).filter((h) => h.task === id).forEach((h) => {
      events.push({ at: ms(h.at), kind: "halt", text: "Halted", sub: h.reason + (h.gateRun ? " · gate run " + shortRun(h.gateRun) : ""), c: "--bad" });
    });
    if (t.mergedAt) {
      const g = gateBy[t.mergeGateRun];
      events.push({ at: ms(t.mergedAt), kind: "merge", text: "Merged", codes: t.commits || [], sub: g ? "merge gate " + g.verdict : "", c: "--fg" });
    }
    // At the same instant a verdict comes before the stage it starts: a RED gate, then its fix.
    const rank = (e) => (e.kind === "created" ? 0 : e.kind === "gate" && e.text !== "Gate running" ? 1 : 2);
    return events.filter((e) => e.at != null && !Number.isNaN(e.at)).sort((a, b) => a.at - b.at || rank(a) - rank(b));
  }

  // The tool summary of a span and every span under it, in the RunView `tools` shape.
  function toolSummary(spans, spanId) {
    const kids = {};
    let rootSpan = null;
    spans.forEach((s) => {
      if (s.id === spanId) rootSpan = s;
      (kids[s.parent] = kids[s.parent] || []).push(s);
    });
    if (!rootSpan) return null;
    const calls = {};
    const files = [];
    let otherCount = 0, total = 0, droppedPaths = 0, any = false;
    const walk = (s) => {
      if (s.tools) {
        any = true;
        s.tools.calls.forEach((c) => {
          const row = calls[c.tool] || (calls[c.tool] = { tool: c.tool, count: 0, ms: 0 });
          row.count += c.count;
          row.ms += c.ms;
        });
        otherCount += s.tools.otherCount || 0;
        total += s.tools.ms || 0;
        droppedPaths += s.tools.droppedPaths || 0;
        s.tools.files.forEach((f) => { if (files.indexOf(f) < 0) files.push(f); });
      }
      (kids[s.id] || []).forEach(walk);
    };
    walk(rootSpan);
    if (!any) return null;
    const sorted = Object.keys(calls).map((k) => calls[k]).sort((a, b) => b.count - a.count || (a.tool < b.tool ? -1 : 1));
    return { calls: sorted, otherCount, ms: total, files, droppedPaths };
  }

  // What explains a span's red or halted outcome: the RED gate run it is or names, the task's
  // block when it stopped there, and the run's halts. Null when nothing does.
  function failureOf(view, span) {
    const gates = {};
    (view.gates || []).forEach((g) => { gates[g.runId] = g; });
    const task = span.task != null ? (view.tasks || []).find((t) => t.id === span.task) : null;
    const runId = span.gateRun || span.causeGateRun || null;
    const gate = runId && gates[runId] && gates[runId].failure ? gates[runId] : null;
    const block = span.phase === "task" && task && task.blocked ? task.blocked : null;
    const halts = span.phase === "run" && span.outcome === "halted" ? openHalts(view) : [];
    if (!gate && !block && !halts.length) return null;
    return { gate, block, halts, gateOf: (id) => gates[id] || null };
  }

  const NEVER_ENDED = "Never ended; no end event recorded.";
  const NO_REASON = "No reason recorded.";

  // A span's one-line failure reason: the builder's, its gate run's for a step row the page
  // derives, or "never ended" for a span still open in a report. Null for a span that is ok or
  // still running live.
  function failureReason(view, s, live) {
    if (s.failureReason) return s.failureReason;
    const open = s.open != null ? s.open : s.end == null;
    if (open) return live ? null : NEVER_ENDED;
    if (s.outcome == null || s.outcome === "ok") return null;
    const spans = view.spans || [];
    // A red step row the page derives takes the reason of the builder's red step of that run.
    const step = s.gateRun ? spans.find((x) => (x.phase === "step" || x.phase === "tier") && x.gateRun === s.gateRun && x.outcome === "red" && x.failureReason) : null;
    const gate = s.gateRun ? spans.find((x) => x.phase === "gate" && x.gateRun === s.gateRun && x.failureReason) : null;
    return step ? step.failureReason : gate ? gate.failureReason : NO_REASON;
  }

  // `file:line`, `file`, or null for a finding or test no file locates.
  const location = (file, line) => (file == null ? null : line == null ? file : file + ":" + line);

  // `text` cut to `max` characters with an ellipsis.
  const clip = (text, max) => (text.length > max ? text.slice(0, Math.max(0, max - 1)) + "…" : text);

  // Halts with no resume yet: the builder fills `answer` and `waitMs` only from a `build.resume`.
  const openHalts = (view) => (view.halts || []).filter((h) => h.answer == null && h.waitMs == null);

  // The newest time anything of a task happened: a span starting or ending, a halt or its resume.
  function lastTaskEventMs(view, id) {
    const times = [];
    (view.spans || []).filter((s) => s.task === id).forEach((s) => times.push(ms(s.start), ms(s.end)));
    (view.halts || []).filter((h) => h.task === id).forEach((h) => {
      times.push(ms(h.at));
      if (h.waitMs != null) times.push(ms(h.at) + h.waitMs);
    });
    const known = times.filter((t) => t != null && !Number.isNaN(t));
    return known.length ? Math.max.apply(null, known) : null;
  }

  // The now strip: 1 card per task with an open task span, naming its newest open stage.
  function workers(view, nowMs, stallMin) {
    const spans = view.spans || [];
    const halted = {};
    openHalts(view).forEach((h) => { if (h.task != null) halted[h.task] = h; });
    return spans.filter((s) => s.phase === "task" && s.task != null && s.end == null).map((ts) => {
      const stages = spans.filter((s) => s.task === ts.task && s.id !== ts.id && s.end == null)
        .sort((a, b) => ms(b.start) - ms(a.start));
      const stage = stages[0] || null;
      const last = lastTaskEventMs(view, ts.task);
      return {
        task: ts.task, phase: stage ? stage.phase : "task", gateRun: stage ? stage.gateRun : null,
        elapsedMs: nowMs - ms(ts.start), lastEventMs: last,
        stalled: last != null && nowMs - last > stallMin * 60000, halted: !!halted[ts.task],
        halt: halted[ts.task] || null
      };
    });
  }

  // Tasks whose open span has had no event of that task for `stallMin` minutes at `nowMs`.
  const stalls = (view, nowMs, stallMin) => workers(view, nowMs, stallMin).filter((w) => w.stalled).map((w) => w.task);

  // The header's line for a run's time box: its minutes and where they came from, then the clock
  // times starts stop, the cutoff comes and the box ends. `null` for a run without a box.
  const clock = (iso) => iso.slice(11, 16) + " UTC";
  function timeBoxText(run) {
    const box = run && run.timeBox;
    if (!box) return null;
    const from = { config: "config", flag: "--time-box", default: "default" }[box.source] || box.source;
    return `box ${box.budgetMin} min (${from}): starts stop ${clock(box.noNewStartsAt)}, cutoff ${clock(box.cutoffAt)}, ends ${clock(box.endsAt)}`;
  }

  // A report of a run that hadn't ended says when it was taken; null for a final report.
  function snapshotText(run) {
    if (!run || !run.snapshotAt) return null;
    return `Snapshot at ${run.snapshotAt.slice(0, 10)} ${clock(run.snapshotAt)}, run still ${run.state}`;
  }

  // Gate runs in time order: by the end of each run's gate span, falling back to the view's order
  // for a run with no span.
  function gatesInTime(view, gates) {
    const ended = {};
    (view.spans || []).forEach((s) => { if (s.phase === "gate" && s.gateRun && s.end != null) ended[s.gateRun] = ms(s.end); });
    const index = new Map((view.gates || []).map((g, i) => [g.runId, i]));
    return gates.slice().sort((a, b) => {
      const ta = ended[a.runId], tb = ended[b.runId];
      return (ta != null && tb != null ? ta - tb : 0) || index.get(a.runId) - index.get(b.runId);
    });
  }

  // A task's newest gate run, or null when it has none.
  function latestGate(view, id) {
    const own = gatesInTime(view, (view.gates || []).filter((g) => g.task === id));
    return own.length ? own[own.length - 1] : null;
  }

  // Gate runs of a task that came after its first RED one.
  function gateRetries(view) {
    const byTask = {};
    (view.gates || []).forEach((g) => { if (g.task != null) (byTask[g.task] = byTask[g.task] || []).push(g); });
    return Object.keys(byTask).reduce((total, id) => {
      const runs = gatesInTime(view, byTask[id]);
      const firstRed = runs.findIndex((g) => g.verdict === "RED");
      return total + (firstRed < 0 ? 0 : runs.length - firstRed - 1);
    }, 0);
  }

  const BLOCKED_STATUS = ["blocked", "needs-replan", "abandoned"];
  const plural = (n, one, many) => (n === 1 ? one : many || one + "s");

  // Each tab's badges, by tab id: what the tab would show that needs a look, so it reads from any
  // tab. A badge is `{key, kind, n, text, title}`; a zero count gets none. `now` is the live clock,
  // null for a report, where an open span never ended; a stall needs both `now` and `stallMin`.
  function tabBadges(view, opts) {
    const o = opts || {};
    const live = o.now != null;
    const spans = view.spans || [], tasks = view.tasks || [], gates = view.gates || [];
    const badge = (key, kind, n, text, title) => (n > 0 ? [{ key, kind, n, text, title }] : []);
    const halts = openHalts(view);
    const haltedTask = new Set(halts.filter((h) => h.task != null).map((h) => h.task));
    // Tier and step spans repeat their gate's outcome, so a RED gate counts once.
    // A warm-up step the baseline recorded failed as expected, so it isn't counted.
    const failed = spans.filter((s) => (s.outcome === "red" || s.outcome === "halted") && !s.baseline && s.phase !== "tier" && s.phase !== "step").length;
    const stalled = live && typeof o.stallMin === "number" ? stalls(view, o.now, o.stallMin).length : 0;
    const unended = live ? 0 : spans.filter((s) => s.end == null).length;
    const blocked = tasks.filter((t) => BLOCKED_STATUS.indexOf(t.status) >= 0 || haltedTask.has(t.id)).length;
    const active = tasks.filter((t) => t.status === "in-progress" && !haltedTask.has(t.id)).length;
    const merged = tasks.filter((t) => t.status === "done").length;
    const red = gates.filter((g) => g.verdict === "RED").length;
    const retries = gateRetries(view);
    const unproven = (view.proofs || []).filter((p) => p.outcome !== "proven").length;
    const uncovered = (view.spec || []).filter((q) => !(q.tasks || []).length).length;
    const pending = tasks.filter((t) => t.tokens == null).length;
    return {
      overview: badge("halted", "bad", halts.length, halts.length + " halted", halts.length + " open " + plural(halts.length, "halt")),
      timeline: badge("failed", "bad", failed, failed + " failed", failed + " red or halted " + plural(failed, "span"))
        .concat(badge("stalled", "warn", stalled, stalled + " stalled", stalled + " " + plural(stalled, "task") + " quiet past stall_min"))
        .concat(badge("unended", "plain", unended, unended + " open", unended + " " + plural(unended, "span") + " never ended")),
      board: badge("blocked", "bad", blocked, blocked + " blocked", blocked + " " + plural(blocked, "task") + " blocked or halted")
        .concat(badge("active", "info", active, active + " in flight", active + " " + plural(active, "task") + " in progress")),
      graph: badge("merged", "plain", merged, merged + "/" + tasks.length, merged + " of " + tasks.length + " tasks merged"),
      spec: badge("uncovered", "warn", uncovered, uncovered + " uncovered", uncovered + " " + plural(uncovered, "requirement") + " no task covers"),
      gates: badge("red", "bad", red, red + " RED", red + " RED gate " + plural(red, "run"))
        .concat(badge("retries", "warn", retries, retries + " " + plural(retries, "retry", "retries"), retries + " gate " + plural(retries, "run") + " after a RED one of the same task"))
        .concat(badge("unproven", "warn", unproven, unproven + " not proven", unproven + " changed " + plural(unproven, "test") + " prove couldn't prove")),
      tokens: badge("pending", "plain", pending, pending + " pending", pending + " " + plural(pending, "task") + " with tokens not yet ingested")
    };
  }

  // The Validation tab's groups: 1 per task a row runs after, in ledger order, then tasks the
  // ledger lacks, then rows whose report named no task. A row that runs after several tasks shows
  // under each. Each group's waiting rows come last, as its "waiting on" rows.
  function validationGroups(view) {
    const v = view.validation;
    if (!v) return [];
    const order = (view.tasks || []).map((t) => t.id);
    const byTask = new Map();
    const add = (task, row) => { if (!byTask.has(task)) byTask.set(task, []); byTask.get(task).push(row); };
    v.rows.forEach((row) => { if (row.runsAfter.length) row.runsAfter.forEach((t) => add(t, row)); else add(null, row); });
    const rank = (task) => (task == null ? Infinity : order.indexOf(task) < 0 ? order.length : order.indexOf(task));
    return [...byTask.keys()].sort((a, b) => rank(a) - rank(b) || String(a).localeCompare(String(b))).map((task) => {
      const rows = byTask.get(task);
      return { task, rows: rows.filter((r) => r.result !== "waiting"), waiting: rows.filter((r) => r.result === "waiting") };
    });
  }

  // The Validation tab's badges: its red, unverified, waiting and abandoned counts.
  function validationBadges(view) {
    const v = view.validation;
    if (!v) return [];
    const c = v.counts;
    const badge = (key, kind, n, text, title) => (n > 0 ? [{ key, kind, n, text, title }] : []);
    return badge("red", "bad", c.red, c.red + " red", c.red + " red validation " + plural(c.red, "row"))
      .concat(badge("unverified", "warn", c.unverified, c.unverified + " unverified", c.unverified + " validation " + plural(c.unverified, "row") + " with no answer"))
      .concat(badge("waiting", "plain", c.waiting, c.waiting + " waiting", c.waiting + " validation " + plural(c.waiting, "row") + " waiting on a task"))
      .concat(badge("abandoned", "bad", c.abandoned || 0, c.abandoned + " abandoned", c.abandoned + " validation " + plural(c.abandoned, "row") + " whose task was abandoned"));
  }

  // A link to a file a run left, relative to the page: a report's folder keeps a copy under its
  // view's `evidenceBase`, and the live page at `/` reaches `/runs/`. With `offsetMs` it opens the
  // video there.
  function evidenceHref(run, path, offsetMs, base) {
    const href = (base || "../runs/") + encodeURIComponent(run) + "/" + String(path).split("/").map(encodeURIComponent).join("/");
    return offsetMs == null ? href : href + "#t=" + Math.max(0, offsetMs) / 1000;
  }

  // Whether the page may link a run's file: a report links only the files its folder holds, as
  // its view's `evidenceFiles` lists them; a live page, whose view has none, links every one.
  function carries(view, run, path) {
    const files = view && view.evidenceFiles;
    return files == null || files.includes(run + "/" + path);
  }

  // Why a final pass or a kept XCUITest left no video or no contact sheet.
  const GAP_TEXT = {
    recorderBusy: "a recording outside the harness held the simulator past the 5-minute retry bound",
    recordLockTimedOut: "another final pass held the recording slot past the wait",
    recordFailed: "record start or record stop failed",
    sheetFailed: "the contact sheet couldn't be made from the video",
    noVideoAttachment: "the UI test kept no screen recording in its result bundle"
  };
  function gapText(reason) {
    return GAP_TEXT[reason] || "no reason recorded (" + reason + ")";
  }

  // The kept flows list: 1 group per `[[flows]]` entry, each with its tests in order.
  function keptFlowGroups(view) {
    const v = view.validation;
    if (!v || !v.keptFlows) return [];
    const groups = new Map();
    v.keptFlows.forEach((k) => {
      const key = k.name == null ? null : k.name;
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(k);
    });
    return [...groups.entries()].map(([name, flows]) => ({ name, flows }));
  }

  root.RunViewModel = {
    validationGroups, validationBadges, evidenceHref, carries, gapText, keptFlowGroups,
    latestGate, tabBadges, stalls, openHalts, workers, failureOf, failureReason, location, clip, normalize, lanes, scale, labelFits, blocks, activity, waveOf, toolSummary, durationText, timeBoxText, snapshotText,
    lastEventMs, gateTier, sum, fmtTok, fmtTokens, fmtUSD, costStat, fmtMin, fmtMs, shortRun
  };
})(globalThis);
