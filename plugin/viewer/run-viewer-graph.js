// The plan graph module: the tasks as a dependency graph in waves left to right, 1 node per task
// coloured by its board lane and 1 edge per dep. Loaded after the core page as a classic script;
// it publishes `RunViewGraph` and registers with the page when the page is there.
(function (root) {
  // A dep on an id outside `tasks` is left out here; the module reports it as a damage line.
  function cycleIn(tasks, by) {
    const state = new Map();
    const stack = [];
    let found = null;
    const visit = (id) => {
      state.set(id, "open");
      stack.push(id);
      for (const d of by.get(id).deps || []) {
        if (found) break;
        if (!by.has(d)) continue;
        if (state.get(d) === "open") found = stack.slice(stack.indexOf(d));
        else if (!state.has(d)) visit(d);
      }
      stack.pop();
      state.set(id, "done");
    };
    for (const t of tasks) {
      if (found) break;
      if (!state.has(t.id)) visit(t.id);
    }
    return found;
  }

  // Each task's wave is the length of its longest dep chain. Then 1 pass orders each wave by the
  // mean centred position of its deps, so edges from a wave's top tend to stay at the top.
  function layers(tasks) {
    const by = new Map(tasks.map((t) => [t.id, t]));
    const cycle = cycleIn(tasks, by);
    if (cycle) return { waves: [], cycle };
    const wave = new Map();
    const waveOf = (id) => {
      if (!wave.has(id)) {
        const known = (by.get(id).deps || []).filter((d) => by.has(d));
        wave.set(id, known.length ? 1 + Math.max(...known.map(waveOf)) : 0);
      }
      return wave.get(id);
    };
    const waves = [];
    tasks.forEach((t) => (waves[waveOf(t.id)] = waves[waveOf(t.id)] || []).push(t.id));
    const pos = new Map();
    waves.forEach((w, i) => {
      if (i > 0) {
        const key = (id) => {
          const known = (by.get(id).deps || []).filter((d) => pos.has(d));
          return known.reduce((a, d) => a + pos.get(d), 0) / known.length;
        };
        const keys = new Map(w.map((id) => [id, key(id)]));
        w.sort((a, b) => keys.get(a) - keys.get(b));
      }
      w.forEach((id, j) => pos.set(id, j - (w.length - 1) / 2));
    });
    return { waves, cycle: null };
  }

  root.RunViewGraph = { layers };

  const runViewer = root.runViewer;
  if (!runViewer || typeof document === "undefined") return;

  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  const ms = (iso) => (iso == null ? null : Date.parse(iso));
  // Plan stages come from phase spans; before tasks run spec-read, plan and contract, after them final.
  const PRE = ["spec-read", "plan", "contract"];
  const POST = ["final"];
  const STAGE_LABEL = { "spec-read": "spec read", plan: "plan", contract: "contract", final: "final" };
  const NW = 168, NH = 52, GX = 44, PAD = 20, ROW = 72;
  // A 12px monospace id fits about 18 characters in a node; the tooltip and label keep the whole id.
  const fit = (s) => (s.length > 18 ? s.slice(0, 17) + "…" : s);

  // Without the board module a task's lane comes from its status alone.
  function lanesOf(view) {
    const out = {};
    if (root.RunViewBoard) {
      const cols = root.RunViewBoard.columns(view);
      Object.keys(cols).forEach((lane) => cols[lane].forEach((c) => (out[c.id] = lane)));
      return out;
    }
    (view.tasks || []).forEach((t) => {
      out[t.id] = t.status === "done" ? "merged" : ["blocked", "needs-replan", "abandoned"].includes(t.status) ? "blocked" : t.status === "in-progress" ? "building" : "queued";
    });
    return out;
  }

  function stagesOf(view) {
    const out = {};
    (view.spans || []).forEach((s) => {
      if (!STAGE_LABEL[s.phase]) return;
      const st = out[s.phase] || (out[s.phase] = { phase: s.phase, start: ms(s.start), end: ms(s.end), open: false });
      st.start = Math.min(st.start, ms(s.start));
      if (s.end == null) st.open = true; else st.end = Math.max(st.end || 0, ms(s.end));
    });
    return out;
  }

  // The graph's nodes: plan stages present in the spans, chained around the tasks.
  function nodesOf(view) {
    const tasks = view.tasks || [];
    const ids = new Set(tasks.map((t) => t.id));
    const stages = stagesOf(view);
    const pre = PRE.filter((p) => stages[p]);
    const post = POST.filter((p) => stages[p]);
    const key = (p) => "@" + p;
    const nodes = [];
    pre.forEach((p, i) => nodes.push({ key: key(p), stage: stages[p], deps: i ? [key(pre[i - 1])] : [], stageDeps: true }));
    const depended = new Set(tasks.flatMap((t) => (t.deps || []).filter((d) => ids.has(d))));
    tasks.forEach((t) => {
      const known = (t.deps || []).filter((d) => ids.has(d));
      const lead = !known.length && pre.length ? [key(pre[pre.length - 1])] : [];
      nodes.push({ key: t.id, task: t, deps: lead.concat(known), lead: lead.length });
    });
    const sinks = tasks.filter((t) => !depended.has(t.id)).map((t) => t.id);
    post.forEach((p, i) => nodes.push({ key: key(p), stage: stages[p], deps: i ? [key(post[i - 1])] : sinks, stageDeps: true }));
    return nodes;
  }

  let mount = null, shape = null;

  function taskBits(n, lane) {
    const t = n.task;
    const files = t.writes.length + (t.writes.length === 1 ? " file" : " files");
    const title = t.brief && t.brief.title ? `${t.id}: ${t.brief.title}` : t.id;
    return { cls: `gnode ln-${lane}`, sub: `${files} · ${t.model}`, title, label: `${t.id}, ${lane}, writes ${files}, ${t.model}` };
  }
  function stageBits(n, cut) {
    const s = n.stage;
    const state = s.open ? "running" : "done";
    const sub = s.open ? `running ${root.RunViewModel.fmtMin(Math.max(0, cut - s.start) / 60000)}` : root.RunViewModel.fmtMin(Math.max(0, s.end - s.start) / 60000);
    const name = STAGE_LABEL[s.phase];
    return { cls: `gnode stage ln-${state === "done" ? "merged" : "building"}`, sub, title: `${name} stage`, label: `${name} stage, ${state}, ${sub}` };
  }

  function draw(view, nodes, waves) {
    const by = new Map(nodes.map((n) => [n.key, n]));
    const maxRows = Math.max(1, ...waves.map((w) => w.length));
    const GH = PAD * 2 + NH + (maxRows - 1) * ROW, mid = GH / 2;
    const GW = PAD * 2 + waves.length * NW + Math.max(0, waves.length - 1) * GX;
    waves.forEach((w, i) => w.forEach((k, j) => {
      const n = by.get(k);
      n.x = PAD + i * (NW + GX);
      // A lone node sits level with its deps; a crowded wave spreads around the middle.
      n.cy = w.length === 1 && n.deps.length ? n.deps.reduce((a, d) => a + by.get(d).cy, 0) / n.deps.length : mid + (j - (w.length - 1) / 2) * ROW;
    }));
    let svg = `<svg class="graph" viewBox="0 0 ${GW} ${GH}" style="min-width:${GW}px" role="group" aria-label="Plan dependency graph">
      <defs><marker id="graph-arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path class="arrow" d="M0 0 L10 5 L0 10 z"/></marker></defs>`;
    nodes.forEach((n) => n.deps.forEach((d, i) => {
      const a = by.get(d), x1 = a.x + NW, x2 = n.x - 2, mx = (x1 + x2) / 2;
      const kind = n.stageDeps || i < (n.lead || 0) ? "stage" : "dep";
      svg += `<path class="edge ${kind}" d="M${x1} ${a.cy} C${mx} ${a.cy}, ${mx} ${n.cy}, ${x2} ${n.cy}" marker-end="url(#graph-arrow)"/>`;
    }));
    nodes.forEach((n) => {
      const attr = n.task ? `data-task="${esc(n.task.id)}" aria-haspopup="dialog" aria-expanded="false"` : `data-stage="${esc(n.stage.phase)}"`;
      const name = n.task ? n.task.id : STAGE_LABEL[n.stage.phase];
      svg += `<g class="gnode" tabindex="0" role="button" ${attr}><title></title>
        <rect class="box" x="${n.x}" y="${n.cy - NH / 2}" width="${NW}" height="${NH}" rx="8"/>
        <circle class="dot" cx="${n.x + 14}" cy="${n.cy - 8}" r="4"/>
        <text class="gid" x="${n.x + 24}" y="${n.cy - 4}">${esc(fit(name))}</text>
        <text class="gsub" x="${n.x + 24}" y="${n.cy + 14}"></text></g>`;
    });
    mount.querySelector(".graph-scroll").innerHTML = svg + `</svg>`;
  }

  // Classes, labels and tooltips change in place, so a focused node and the drawer's opener survive a poll.
  function paint(view, nodes) {
    const lanes = lanesOf(view);
    const cut = root.RunViewModel.lastEventMs(view);
    nodes.forEach((n) => {
      const el = n.task
        ? mount.querySelector(`.gnode[data-task="${CSS.escape(n.task.id)}"]`)
        : mount.querySelector(`.gnode[data-stage="${CSS.escape(n.stage.phase)}"]`);
      const bits = n.task ? taskBits(n, lanes[n.task.id] || "queued") : stageBits(n, cut);
      const keep = el.classList.contains("sel");
      el.setAttribute("class", bits.cls + (keep ? " sel" : ""));
      if (n.task) el.dataset.lane = lanes[n.task.id] || "queued";
      el.setAttribute("aria-label", bits.label);
      el.querySelector("title").textContent = bits.title;
      el.querySelector(".gsub").textContent = bits.sub;
    });
  }

  function stageRows(phase, view) {
    const s = stagesOf(view)[phase];
    const fmtMin = root.RunViewModel.fmtMin;
    const t0 = ms(view.run.startedAt);
    return [["stage", STAGE_LABEL[phase]], ["start", "+" + fmtMin(Math.max(0, s.start - t0) / 60000)],
      ["duration", s.open ? "running" : fmtMin(Math.max(0, s.end - s.start) / 60000)]];
  }

  let current = null;
  function open(g) {
    if (g.dataset.task) runViewer.openTaskDrawer(g.dataset.task, g);
    else if (g.dataset.stage && current) runViewer.openPopover(g, stageRows(g.dataset.stage, current), STAGE_LABEL[g.dataset.stage]);
  }

  function build(m) {
    mount = m;
    shape = null;
    mount.innerHTML = `<div class="head" style="justify-content:space-between"><h2>Plan</h2>
        <div class="legend"><span style="--c:var(--ok)">merged</span><span style="--c:var(--accent)">building</span><span style="--c:var(--warn)">gating</span><span style="--c:var(--bar-review)">review</span><span style="--c:var(--bad)">blocked</span><span style="--c:var(--muted)">queued</span></div></div>
      <div class="graph-notes"></div>
      <div class="graph-scroll" tabindex="0" aria-label="Plan dependency graph, scrolls horizontally"></div>`;
    const scroll = mount.querySelector(".graph-scroll");
    scroll.addEventListener("click", (e) => { const g = e.target.closest(".gnode"); if (g) open(g); });
    scroll.addEventListener("keydown", (e) => {
      const g = e.target.closest(".gnode");
      if (g && (e.key === "Enter" || e.key === " ")) { e.preventDefault(); open(g); }
    });
  }

  function update(view) {
    current = view;
    const nodes = nodesOf(view);
    const ids = new Set((view.tasks || []).map((t) => t.id));
    const unknown = (view.tasks || []).flatMap((t) => (t.deps || []).filter((d) => !ids.has(d)).map((d) => `${t.id} → ${d}`));
    const { waves, cycle } = layers(nodes.map((n) => ({ id: n.key, deps: n.deps })));
    const notes = [];
    if (cycle) notes.push(`plan graph: dep cycle ${cycle.concat(cycle[0]).join(" → ")}; no graph drawn`);
    if (unknown.length) notes.push(`plan graph: dep on a task outside the plan, not drawn: ${unknown.join(", ")}`);
    mount.querySelector(".graph-notes").innerHTML = notes.map((n) => `<p class="damage-line">${esc(n)}</p>`).join("");
    if (cycle) {
      shape = null;
      mount.querySelector(".graph-scroll").replaceChildren();
      return;
    }
    const next = JSON.stringify(nodes.map((n) => [n.key, n.deps]));
    if (next !== shape) {
      const focused = document.activeElement;
      const refocus = focused && mount.contains(focused) ? (focused.dataset.task ? `[data-task="${CSS.escape(focused.dataset.task)}"]` : focused.dataset.stage ? `[data-stage="${CSS.escape(focused.dataset.stage)}"]` : null) : null;
      draw(view, nodes, waves);
      shape = next;
      const again = refocus && mount.querySelector(`.gnode${refocus}`);
      if (again) again.focus({ preventScroll: true });
    }
    paint(view, nodes);
  }

  runViewer.register("graph", {
    render(view, m) {
      if (mount !== m || !m.querySelector(".graph-scroll")) build(m);
      update(view);
    },
    apply: update
  });
})(globalThis);
