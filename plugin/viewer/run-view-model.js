// Pure functions over a RunView: merging partials, laying out the timeline, and formatting.
// Loaded as a classic script so the report can inline it; it publishes one global.
(function (root) {
  // The key each RunView array merges on. A partial row replaces the row with the same key.
  const KEYS = {
    spec: (x) => x.id,
    tasks: (x) => x.id,
    roles: (x) => x.role,
    spans: (x) => x.id,
    gates: (x) => x.runId,
    proofs: (x) => x.gateRun + "\u0000" + x.test,
    halts: (x) => (x.task || "") + "\u0000" + x.at,
    damage: (x) => x.source + "\u0000" + x.reason
  };

  function mergeBy(rows, partial, key) {
    const out = rows.slice();
    const index = new Map(out.map((row, i) => [key(row), i]));
    partial.forEach((row) => {
      const k = key(row);
      if (index.has(k)) out[index.get(k)] = row;
      else { index.set(k, out.length); out.push(row); }
    });
    return out;
  }

  function apply(view, partial) {
    const out = Object.assign({}, view);
    Object.keys(partial || {}).forEach((field) => {
      const value = partial[field];
      out[field] = KEYS[field] && Array.isArray(value) ? mergeBy(view[field] || [], value, KEYS[field]) : value;
    });
    return out;
  }

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
    return s.phase.replace(/-/g, " ");
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
            outcome: st.verdict === "RED" ? "red" : "ok", gateRun: g.runId, task: gs.task, ms: st.ms, tier, approximate
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
        else events.push({ at: ms(s.end), kind: "gate", text: "Gate " + verdict, codes: g ? Object.keys(g.ruleCounts || {}) : [], sub, c: verdict === "RED" ? "--bad" : "--ok" });
      }
    });
    (view.halts || []).filter((h) => h.task === id).forEach((h) => {
      events.push({ at: ms(h.at), kind: "halt", text: "Halted", sub: h.reason, c: "--bad" });
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

  root.RunViewModel = {
    apply, stalls, openHalts, workers, normalize, lanes, scale, labelFits, blocks, activity, waveOf, toolSummary, durationText,
    lastEventMs, gateTier, sum, fmtTok, fmtTokens, fmtMin, fmtMs, shortRun
  };
})(globalThis);
