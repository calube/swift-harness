(function () {
  const view = JSON.parse(document.getElementById("run-view").textContent);
  const $ = (id) => document.getElementById(id);
  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  const sum = (t) => t.input + t.output + t.cacheRead + t.cacheWrite;
  const fmtTok = (n) => n >= 1e6 ? (n / 1e6).toFixed(2) + "M" : Math.round(n / 1e3) + "k";
  const fmtMin = (m) => { const s = Math.round(m * 60); return s >= 60 ? Math.floor(s / 60) + "m " + String(s % 60).padStart(2, "0") + "s" : s + "s"; };
  const fmtMs = (ms) => fmtMin(ms / 60000);
  const shortRun = (id) => id.slice(9, 15) + "…" + id.slice(-4);
  const verdictChip = (v) => `<span class="chip ${v === "GREEN" ? "ok" : v === "RED" ? "bad" : "warn"}">${esc(v)}</span>`;

  // header
  const r = view.run;
  const wall = Math.max(...view.spans.map((s) => s.end));
  const totalTok = view.tasks.reduce((a, t) => a + sum(t.tokens), 0) + view.roles.filter((x) => x.role === "orchestrator" || x.role === "explorer").reduce((a, x) => a + sum(x.tokens), 0);
  $("meta").innerHTML = [`run ${esc(r.id)}`, `plan ${esc(r.plan)}`, `preset ${esc(r.preset)}`, `started ${esc(r.startedAt.replace("T", " ").replace("Z", " UTC"))}`].map((x) => `<span>${x}</span>`).join("");
  const proven = view.proofs.filter((p) => p.outcome === "proven").length;
  const stats = [
    [fmtMin(wall), "wall time"],
    [fmtTok(totalTok), "tokens"],
    [view.tasks.length + " tasks", "3 workers in parallel"],
    [proven + " / " + new Set(view.proofs.map((p) => p.test)).size, "tests proven"],
    [view.gates.length + " gates", view.gates.filter((g) => g.verdict === "RED").length + " RED, then fixed"],
    [view.halts.length + " halts", "no stalls"]
  ];
  $("stats").innerHTML = stats.map(([b, s]) => `<div class="stat"><b>${b}</b><span>${s}</span></div>`).join("");

  // timeline
  const colour = { run: "--bar-phase", "spec-read": "--bar-phase", discover: "--bar-phase", explore: "--bar-phase", plan: "--bar-phase", contract: "--bar-phase", final: "--bar-phase", task: "--bar-task", worker: "--bar-worker", review: "--bar-review", fix: "--bar-worker", merge: "--bar-merge" };
  const kids = {};
  view.spans.forEach((s) => { (kids[s.parent] = kids[s.parent] || []).push(s); });
  const rows = [];
  function lane(span, depth) {
    // A task's stages share 1 row under the task row, so a worker's whole story reads left to right.
    rows.push({ depth, spans: [span], label: span.label, isTask: span.phase === "task" });
    const children = kids[span.id] || [];
    if (span.phase === "task" || span.phase === "final") {
      if (children.length) rows.push({ depth: depth + 1, spans: children, label: span.phase === "task" ? "stages" : "gate" });
      const gates = children.filter((c) => c.gateRun && c.phase !== "merge");
      gates.forEach((gs) => {
        const g = view.gates.find((x) => x.runId === gs.gateRun);
        if (!g) return;
        const scale = (gs.end - gs.start) / (g.ms / 60000);
        const tiers = [...new Set(g.steps.map((st) => st.tier))];
        tiers.forEach((tier) => {
          rows.push({ depth: depth + 2, label: `${tier} · ${g.verdict === "RED" ? "RED run" : "run"} ${shortRun(g.runId)}`, spans: g.steps.filter((st) => st.tier === tier).map((st) => ({
            id: gs.id + st.step, phase: "step", label: st.step, start: gs.start + (st.startMs / 60000) * scale, end: gs.start + ((st.startMs + st.ms) / 60000) * scale,
            outcome: st.verdict === "RED" ? "red" : "ok", gateRun: g.runId, task: gs.task, ms: st.ms, tier
          })) });
        });
      });
    } else {
      children.forEach((c) => lane(c, depth + 1));
    }
  }
  lane(view.spans[0], 0);

  const pct = (m) => (m / wall) * 100;
  let html = `<div class="tl-row axis"><div class="tl-label" style="font-weight:600;color:var(--muted)">span</div><div class="tl-track">`;
  for (let m = 0; m <= wall; m += 5) html += `<div class="tick" style="left:${pct(m)}%">${m}m</div>`;
  html += `</div></div><div class="grid-lines">`;
  for (let m = 5; m <= wall; m += 5) html += `<i style="left:${pct(m)}%"></i>`;
  html += `</div>`;
  const all = {};
  rows.forEach((row) => {
    html += `<div class="tl-row"><div class="tl-label" style="padding-left:${8 + row.depth * 14}px;${row.isTask ? "font-weight:600" : row.depth > 2 ? "color:var(--muted)" : ""}">${esc(row.label)}</div><div class="tl-track">`;
    row.spans.forEach((s) => {
      all[s.id] = s;
      const c = s.phase === "gate" || s.phase === "step" ? (s.outcome === "red" ? "--bar-red" : "--bar-gate") : colour[s.phase] || "--bar-phase";
      const textColor = s.phase === "merge" ? "var(--bg)" : "var(--bar-text)";
      html += `<button class="bar" data-id="${esc(s.id)}" style="left:${pct(s.start)}%;width:calc(${pct(s.end - s.start)}% - 2px);background:var(${c});color:${textColor}" title="${esc(s.label)} · ${fmtMin(s.end - s.start)}" aria-label="${esc(s.label)}, ${esc(s.phase)}, ${fmtMin(s.end - s.start)}" aria-haspopup="dialog" aria-expanded="false">${esc(s.label)}</button>`;
    });
    html += `</div></div>`;
  });
  $("tl").innerHTML = html;

  const scroller = $("tl-scroll");
  const tl = $("tl");

  // Rough width of a bar label at 11px plus its 12px of padding.
  function fitBars() {
    tl.querySelectorAll(".bar").forEach((b) => {
      const s = all[b.dataset.id];
      b.classList.toggle("notext", b.clientWidth < s.label.length * 6.3 + 12);
    });
  }

  // span popover
  const pop = $("pop");
  const sheet = window.matchMedia("(max-width: 520px)");
  let openBar = null;

  function toolsHtml(t, filesLabel = "Files touched") {
    if (!t) return `<p class="sub">no tool activity recorded</p>`;
    const counts = Object.entries(t.counts).sort((a, b) => b[1] - a[1]);
    const calls = counts.reduce((a, [, n]) => a + n, 0);
    const shown = t.files.slice(0, 6);
    const more = t.files.length - shown.length;
    const files = t.files.length
      ? `<ul class="pop-files">${shown.map((f) => `<li>${esc(f)}</li>`).join("")}${more > 0 ? `<li class="more">+${more} more</li>` : ""}</ul>`
      : `<p class="sub">no files touched</p>`;
    return `${counts.length ? `<div class="tags">${counts.map(([k, n]) => `<span class="chip plain num">${esc(k)} ${n}</span>`).join("")}</div>` : ""}
      <p class="sub num">${calls} calls · ${fmtMs(t.toolMs)} tool time</p>
      <h4>${esc(filesLabel)} (${t.files.length})</h4>${files}`;
  }

  function place() {
    if (!openBar) return;
    if (sheet.matches) { pop.style.left = ""; pop.style.top = ""; return; }
    const r = openBar.getBoundingClientRect();
    const m = 8, gap = 6;
    const vw = document.documentElement.clientWidth, vh = window.innerHeight;
    const pw = pop.offsetWidth, ph = pop.offsetHeight;
    const left = Math.min(Math.max(m, r.left), vw - pw - m);
    let top = r.bottom + gap;
    if (top + ph > vh - m) top = r.top - gap - ph;
    if (top < m) top = Math.max(m, vh - ph - m);
    pop.style.left = Math.max(m, left) + "px";
    pop.style.top = top + "px";
  }

  // Timeline bars open the popover; board cards and graph nodes open the task drawer instead.
  function openPop(bar, s = all[bar.dataset.id], filesLabel) {
    if (openBar) closePop(false);
    openBar = bar;
    bar.classList.add("sel");
    bar.setAttribute("aria-expanded", "true");
    const fields = [
      ["phase", s.phase],
      ["task", s.task || "none"],
      ["start", "+" + fmtMin(s.start)],
      ["duration", s.ms ? fmtMs(s.ms) : fmtMin(s.end - s.start)],
      ["gate run", s.gateRun || "none"],
      ["outcome", s.outcome ? (s.outcome === "red" ? "RED" : "GREEN") : "none"]
    ];
    $("pop-title").textContent = s.label;
    $("pop-body").innerHTML = `<dl>${fields.map(([k, v]) => `<dt>${k}</dt><dd class="${k === "gate run" && s.gateRun ? "mono" : ""}">${k === "outcome" && s.outcome ? verdictChip(v) : esc(v)}</dd>`).join("")}</dl>
      <div class="pop-tools"><h4>Tools</h4>${toolsHtml(s.tools, filesLabel)}</div>`;
    pop.hidden = false;
    place();
    pop.querySelector(".pop-close").focus({ preventScroll: true });
  }

  function closePop(restoreFocus = true) {
    if (!openBar) return;
    const bar = openBar;
    openBar = null;
    pop.hidden = true;
    bar.classList.remove("sel");
    bar.setAttribute("aria-expanded", "false");
    if (restoreFocus) bar.focus({ preventScroll: true });
  }

  tl.addEventListener("click", (e) => {
    const b = e.target.closest(".bar");
    if (!b) return;
    if (b === openBar) closePop(); else openPop(b);
  });
  pop.querySelector(".pop-close").addEventListener("click", () => closePop());
  document.addEventListener("keydown", (e) => {
    if (e.key !== "Escape") return;
    if (drawerId) { e.preventDefault(); closeDrawer(); } else if (openBar) { e.preventDefault(); closePop(); }
  });
  document.addEventListener("pointerdown", (e) => {
    if (openBar && !pop.contains(e.target) && !e.target.closest(".bar")) closePop();
  });
  window.addEventListener("scroll", place, { capture: true, passive: true });
  window.addEventListener("resize", () => { fitBars(); place(); });
  sheet.addEventListener("change", place);

  // zoom: scale the track and keep the time at the middle of the visible track in view
  const zoomBtns = [...document.querySelectorAll("#zoom button")];
  function setZoom(z) {
    const labelW = tl.querySelector(".tl-label").offsetWidth;
    const mid = (labelW + scroller.clientWidth) / 2;
    const f = (scroller.scrollLeft + mid - labelW) / (tl.offsetWidth - labelW);
    tl.style.setProperty("--zoom", z);
    scroller.scrollLeft = labelW + f * (tl.offsetWidth - labelW) - mid;
    zoomBtns.forEach((b) => b.setAttribute("aria-pressed", String(Number(b.dataset.z) === z)));
    fitBars();
    place();
  }
  zoomBtns.forEach((b) => b.addEventListener("click", () => setZoom(Number(b.dataset.z))));
  fitBars();

  const specTags = (id) => view.spec.filter((q) => q.tasks.includes(id)).map((q) => q.id);
  const spanOfTask = Object.fromEntries(view.spans.filter((s) => s.phase === "task").map((s) => [s.task, s.id]));

  // plan graph
  const gnodes = [
    ...view.stages.map((st) => ({ id: st.id, span: st.span, deps: st.deps, writes: st.writes, kind: "stage" })),
    ...view.tasks.map((t) => ({ id: t.id, span: spanOfTask[t.id], deps: t.deps, writes: t.writes, kind: "task", model: t.model }))
  ];
  const gBy = Object.fromEntries(gnodes.map((n) => [n.id, n]));
  // Longest-path layering keeps every edge pointing right.
  const layerOf = (n) => n.layer != null ? n.layer : (n.layer = n.deps.length ? 1 + Math.max(...n.deps.map((d) => layerOf(gBy[d]))) : 0);
  gnodes.forEach(layerOf);
  const layers = [];
  gnodes.forEach((n) => (layers[n.layer] = layers[n.layer] || []).push(n));
  const NW = 136, NH = 52, GX = 44, PAD = 20, ROW = 84;
  const maxRows = Math.max(...layers.map((l) => l.length));
  const GH = PAD * 2 + NH + (maxRows - 1) * ROW, mid = GH / 2;
  const GW = PAD * 2 + layers.length * NW + (layers.length - 1) * GX;
  layers.forEach((l, i) => {
    // A lone node sits level with its deps; a crowded layer spreads around the middle.
    l.forEach((n, j) => {
      n.x = PAD + i * (NW + GX);
      n.cy = l.length === 1 && n.deps.length ? n.deps.reduce((a, d) => a + gBy[d].cy, 0) / n.deps.length : mid + (j - (l.length - 1) / 2) * ROW;
    });
  });
  const nodeState = (n) => {
    const s = all[n.span];
    if (!s) return "queued";
    const gatesRed = (kids[n.span] || []).filter((c) => c.phase === "gate").slice(-1).some((c) => c.outcome === "red");
    return gatesRed ? "red" : s.end <= wall ? "done" : "running";
  };
  let svg = `<svg class="graph" viewBox="0 0 ${GW} ${GH}" style="min-width:${GW}px" role="group" aria-label="Plan dependency graph">
    <defs><marker id="arrowhead" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path class="arrow" d="M0 0 L10 5 L0 10 z"/></marker></defs>`;
  gnodes.forEach((n) => n.deps.forEach((d) => {
    const a = gBy[d], x1 = a.x + NW, x2 = n.x - 2, mx = (x1 + x2) / 2;
    svg += `<path class="edge" d="M${x1} ${a.cy} C${mx} ${a.cy}, ${mx} ${n.cy}, ${x2} ${n.cy}" marker-end="url(#arrowhead)"/>`;
  }));
  gnodes.forEach((n) => {
    const st = nodeState(n), files = n.writes.length + (n.writes.length === 1 ? " file" : " files");
    const sub = n.kind === "task" ? `${files} · ${n.model}` : files;
    svg += `<g class="gnode st-${st}" tabindex="0" role="button" data-node="${esc(n.id)}" aria-haspopup="dialog" aria-expanded="false" aria-label="${esc(n.id)}, ${st}, writes ${files}">
      <rect class="box" x="${n.x}" y="${n.cy - NH / 2}" width="${NW}" height="${NH}" rx="8"/>
      <circle class="dot" cx="${n.x + 14}" cy="${n.cy - 8}" r="4"/>
      <text class="gid" x="${n.x + 24}" y="${n.cy - 4}">${esc(n.id)}</text>
      <text class="gsub" x="${n.x + 24}" y="${n.cy + 14}">${esc(sub)}</text></g>`;
  });
  $("graph-scroll").innerHTML = svg + `</svg>`;
  const openNode = (g) => openDrawer(g.dataset.node, g);
  $("graph-scroll").addEventListener("click", (e) => { const g = e.target.closest(".gnode"); if (g) openNode(g); });
  $("graph-scroll").addEventListener("keydown", (e) => {
    const g = e.target.closest(".gnode");
    if (g && (e.key === "Enter" || e.key === " ")) { e.preventDefault(); openNode(g); }
  });

  // board
  const lanes = ["queued", "building", "gating", "review", "merged", "blocked"];
  const snap = view.liveSnapshot;
  const modelOf = Object.fromEntries([...view.tasks, ...snap.extraTasks].map((t) => [t.id, t.model]));
  const lastGateOf = (id) => {
    const g = (kids[spanOfTask[id]] || []).filter((c) => c.phase === "gate").slice(-1)[0];
    return g ? (g.outcome === "red" ? "RED" : "GREEN") : null;
  };
  const halted = new Set(view.halts.map((h) => h.task));
  let curMode = "live";
  function boardCards(mode) {
    const cards = mode === "live"
      ? snap.board.map((b) => {
          const sp = all[spanOfTask[b.task]];
          return { id: b.task, column: b.column, lastGate: b.lastGate, elapsed: sp ? fmtMin(snap.at - sp.start) : "waiting" };
        })
      : view.tasks.map((t) => {
          const sp = all[spanOfTask[t.id]];
          return { id: t.id, column: "merged", lastGate: lastGateOf(t.id), elapsed: fmtMin(sp.end - sp.start) };
        });
    cards.forEach((c) => { if (halted.has(c.id)) c.column = "blocked"; });
    return cards;
  }
  const laneColour = { queued: "--muted", building: "--bar-worker", gating: "--warn", review: "--bar-review", merged: "--ok", blocked: "--bad" };
  function renderBoard(mode) {
    const cards = boardCards(mode);
    $("board-note").textContent = mode === "live"
      ? `Snapshot at +${fmtMin(snap.at)}: ${cards.filter((c) => c.column !== "merged").length} tasks in flight.`
      : `Final state at +${fmtMin(wall)}: every task merged.`;
    $("board").innerHTML = lanes.map((lane) => {
      const inLane = cards.filter((c) => c.column === lane);
      const body = inLane.length ? inLane.map((c) => {
        const tags = specTags(c.id);
        return `<button type="button" class="card" style="--c:var(${laneColour[lane]})" data-task="${esc(c.id)}" aria-haspopup="dialog" aria-expanded="false"
            aria-label="${esc(c.id)}, ${esc(lane)}, ${esc(modelOf[c.id])}, ${esc(c.elapsed)}, last gate ${esc(c.lastGate || "none")}">
          <span class="card-top"><span class="card-id">${esc(c.id)}</span><span class="chip plain">${esc(modelOf[c.id])}</span></span>
          <span class="card-meta"><span class="num">${esc(c.elapsed)}</span>${c.lastGate ? verdictChip(c.lastGate) : `<span class="chip plain">no gate yet</span>`}</span>
          <span class="tags">${tags.length ? tags.map((t) => `<span class="tag">${esc(t)}</span>`).join("") : `<span class="sub" style="color:var(--muted);font-size:12px">no spec id</span>`}</span>
        </button>`;
      }).join("") : `<div class="lane-empty">${lane === "blocked" ? "no halts" : "empty"}</div>`;
      return `<div class="lane${lane === "blocked" ? " blocked" : ""}" role="group" aria-label="${lane}, ${inLane.length} tasks"><div class="lane-head"><span>${lane}</span><span class="num">${inLane.length}</span></div>${body}</div>`;
    }).join("");
  }
  const modeBtns = [...document.querySelectorAll("#board-mode button")];
  function setMode(mode) {
    curMode = mode;
    modeBtns.forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.mode === mode)));
    renderBoard(mode);
  }
  modeBtns.forEach((b) => b.addEventListener("click", () => setMode(b.dataset.mode)));
  $("board").addEventListener("click", (e) => {
    const c = e.target.closest(".card");
    if (c) openDrawer(c.dataset.task, c);
  });
  setMode("live");

  // spec mapping
  const taskBy = Object.fromEntries(view.tasks.map((t) => [t.id, t]));
  const gateBy = Object.fromEntries(view.gates.map((g) => [g.runId, g]));
  $("spec").innerHTML = `<thead><tr><th>requirement</th><th>tasks</th><th>merged commits</th><th>merge gate</th></tr></thead><tbody>` +
    view.spec.map((q) => {
      const ts = q.tasks.map((id) => taskBy[id]);
      const verdicts = ts.map((t) => gateBy[t.mergeGateRun] ? gateBy[t.mergeGateRun].verdict : "GREEN");
      const v = verdicts.includes("RED") ? "RED" : "GREEN";
      return `<tr><td><span class="mono">${esc(q.id)}</span><div class="sub">${esc(q.title)}</div></td>
        <td><div class="tags">${q.tasks.map((t) => `<span class="tag">${esc(t)}</span>`).join("")}</div></td>
        <td><div class="tags">${ts.flatMap((t) => t.commits).map((c) => `<span class="tag">${esc(c)}</span>`).join("")}</div></td>
        <td>${verdictChip(v)}</td></tr>`;
    }).join("") + `</tbody>`;

  // proof
  const outcomeText = { proven: ["failed", "ok", "proven"], "passes-reverted": ["passed", "bad", "not proven"], "compile-only": ["didn't compile", "warn", "not proven"], crashed: ["crashed", "warn", "not proven"], skipped: ["skipped", "warn", "not proven"] };
  $("proof").innerHTML = `<thead><tr><th>test</th><th>with the change reverted</th><th>assertion</th></tr></thead><tbody>` +
    view.proofs.map((p) => {
      const [txt, cls, label] = outcomeText[p.outcome];
      const a = p.assertion ? `<span class="mono">${esc(p.assertion.file.split("/").pop())}:${p.assertion.line}</span><div class="sub">#${esc(p.assertion.kind)}</div>` : `<span class="sub">none failed</span>`;
      return `<tr><td><span class="mono">${esc(p.test)}</span><div class="sub">${esc(p.task)} · base ${esc(p.proofBase)} · run <span class="mono" title="${esc(p.gateRun)}">${esc(shortRun(p.gateRun))}</span></div></td>
        <td><span class="chip ${cls}">${label}</span><div class="sub">${txt}</div></td><td>${a}</td></tr>`;
    }).join("") + `</tbody>`;

  // tokens
  function tokRows(items, labelKey, timeFn) {
    const max = Math.max(...items.map((x) => sum(x.tokens)));
    return items.map((x) => {
      const t = x.tokens, w = (n) => (n / max) * 100;
      return `<div class="tok-row"><span class="mono">${esc(x[labelKey])}</span>
        <div class="tok-bar" title="input ${fmtTok(t.input)}, cache read ${fmtTok(t.cacheRead)}, cache write ${fmtTok(t.cacheWrite)}, output ${fmtTok(t.output)}">
          <i style="width:${w(t.input)}%;background:var(--accent)"></i><i style="width:${w(t.cacheRead)}%;background:var(--bar-review)"></i><i style="width:${w(t.cacheWrite)}%;background:var(--warn)"></i><i style="width:${w(t.output)}%;background:var(--ok)"></i>
        </div><span class="num" style="text-align:right">${fmtTok(sum(t))}${timeFn ? `<div class="sub" style="color:var(--muted);font-size:11px">${timeFn(x)}</div>` : ""}</span></div>`;
    }).join("");
  }
  const taskSpan = Object.fromEntries(view.spans.filter((s) => s.phase === "task").map((s) => [s.task, s]));
  $("tokens").innerHTML = tokRows(view.tasks, "id", (t) => fmtMin(taskSpan[t.id].end - taskSpan[t.id].start));
  $("roles").innerHTML = tokRows(view.roles, "role");

  // gates
  $("gates").innerHTML = view.gates.map((g) => {
    const rules = Object.entries(g.ruleCounts);
    return `<div class="gate"><div class="gate-top">${verdictChip(g.verdict)}<span class="mono">${esc(g.runId)}</span></div>
      <div class="sub" style="color:var(--muted);font-size:12px">${esc(g.task || "final")} · swiftgate ${esc(g.command)} · ${fmtMs(g.ms)} · ${g.tests.passed} passed, ${g.tests.failed} failed, ${g.tests.skipped} skipped</div>
      <div class="steps">${g.steps.map((s) => `<span class="step ${s.verdict === "RED" ? "red" : ""}">${esc(s.tier)} ${esc(s.step)} ${fmtMs(s.ms)}</span>`).join("")}</div>
      ${rules.length ? `<div class="tags">${rules.map(([k, n]) => `<span class="tag">${esc(k)} ${n}</span>`).join("")}</div>` : ""}</div>`;
  }).join("");

  // task drawer: a board card or plan node opens its task as a ticket
  const items = {};
  view.stages.forEach((st) => { items[st.id] = { id: st.id, kind: "stage", brief: st.brief, deps: st.deps, writes: st.writes, span: st.span, commits: [] }; });
  [...view.tasks, ...snap.extraTasks].forEach((t) => { items[t.id] = { id: t.id, kind: "task", brief: t.brief, deps: t.deps, writes: t.writes, span: spanOfTask[t.id], model: t.model, commits: t.commits || [] }; });
  const dependents = (id) => Object.values(items).filter((x) => x.deps.includes(id)).map((x) => x.id);
  // A task's wave counts only task deps, so the plan stages before it don't push it back.
  const waveOf = (id) => {
    const it = items[id];
    if (it.wave) return it.wave;
    const td = it.deps.filter((d) => items[d].kind === "task");
    return (it.wave = td.length ? 1 + Math.max(...td.map(waveOf)) : 1);
  };
  const nowMin = () => (curMode === "live" ? snap.at : wall);
  function statusOf(it) {
    const s = all[it.span], now = nowMin();
    if (it.kind === "stage") return !s || s.start > now ? "queued" : s.end <= now ? "done" : "running";
    if (halted.has(it.id)) return "blocked";
    if (curMode === "live") { const b = snap.board.find((x) => x.task === it.id); if (b) return b.column; }
    return s ? "merged" : "queued";
  }
  const statusChip = { queued: "plain", building: "info", gating: "warn", review: "info", merged: "ok", blocked: "bad", done: "ok", running: "info" };
  const statusVar = Object.assign({ done: "--ok", running: "--accent" }, laneColour);
  const t0 = Date.parse(r.startedAt);
  const clock = (m) => { const d = new Date(t0 + m * 60000); return String(d.getUTCHours()).padStart(2, "0") + ":" + String(d.getUTCMinutes()).padStart(2, "0") + " UTC"; };
  const ago = (m) => { const d = nowMin() - m; return d < 1 ? "just now" : d < 60 ? Math.round(d) + "m ago" : Math.floor(d / 60) + "h ago"; };
  const when = (m) => `<time title="+${fmtMin(m)} · ${clock(m)}">${ago(m)}</time>`;
  const planEnd = all[view.stages.find((st) => st.id === "plan").span].end;
  const md = (txt) => esc(txt).replace(/`([^`]+)`/g, "<code>$1</code>");
  const bullets = (xs) => `<ul class="dr-list">${xs.map((x) => `<li>${md(x)}</li>`).join("")}</ul>`;
  const specColour = Object.fromEntries(view.spec.map((q, i) => [q.id, `--label-${(i % 5) + 1}`]));

  function toolsOf(spanId) {
    if (!all[spanId]) return null;
    const counts = {}, files = new Set();
    let toolMs = 0;
    const walk = (s) => {
      if (s.tools) { toolMs += s.tools.toolMs; Object.entries(s.tools.counts).forEach(([k, n]) => { counts[k] = (counts[k] || 0) + n; }); s.tools.files.forEach((f) => files.add(f)); }
      (kids[s.id] || []).forEach(walk);
    };
    walk(all[spanId]);
    return Object.keys(counts).length ? { counts, toolMs, files: [...files] } : null;
  }

  function activity(it) {
    const ev = [], sp = all[it.span];
    if (it.kind === "task") ev.push({ t: planEnd, text: "Created by plan", c: "--muted" });
    if (sp && it.kind === "stage") ev.push({ t: sp.start, text: "Started", c: "--accent" });
    (kids[it.span] || []).forEach((c) => {
      if (c.phase === "worker") ev.push({ t: c.start, text: "Worker started", sub: it.model + " build worker", c: "--bar-worker" });
      else if (c.phase === "fix") ev.push({ t: c.start, text: "Fix started", sub: c.tools.files.length + " files touched", c: "--warn" });
      else if (c.phase === "review") ev.push({ t: c.start, text: "Review started", c: "--bar-review" });
      else if (c.phase === "merge") ev.push({ t: c.end, text: "Merged", codes: it.commits, sub: "merge gate GREEN", c: "--fg" });
      else if (c.phase === "gate") {
        const g = gateBy[c.gateRun], red = c.outcome === "red";
        const tier = `${c.label.replace("gate ", "")} gate · run ${shortRun(c.gateRun)}`;
        if (c.end > nowMin()) ev.push({ t: c.start, text: "Gate running", sub: tier, c: "--warn" });
        else ev.push({ t: c.end, text: `Gate ${red ? "RED" : "GREEN"}`, codes: g ? Object.keys(g.ruleCounts) : [], sub: tier, c: red ? "--bad" : "--ok" });
      }
    });
    if (sp && it.kind === "stage") ev.push({ t: sp.end, text: "Finished", c: "--ok" });
    if (!sp) ev.push({ t: planEnd, text: "Waiting on " + it.deps.join(", "), c: "--muted" });
    return ev.filter((e) => e.t <= nowMin()).sort((a, b) => a.t - b.t);
  }

  const card = (label, body) => `<section class="dr-card"><h4>${label}</h4>${body}</section>`;

  function renderDrawer(id) {
    const it = items[id], b = it.brief, st = statusOf(it), now = nowMin();
    $("dr-id").textContent = it.id;
    $("dr-status").className = "chip " + statusChip[st];
    $("dr-status").textContent = st;
    $("dr-title").textContent = b.title;

    const tags = specTags(id);
    const merge = (kids[it.span] || []).find((c) => c.phase === "merge");
    const sp = all[it.span];
    const created = it.kind === "task" ? planEnd : 0;
    let finished = `<span class="muted">not yet</span>`;
    if (it.kind === "task" && merge && merge.end <= now) finished = `${it.commits.map((c) => `<code>${esc(c)}</code>`).join("")}<span class="muted">${clock(merge.end)} · ${ago(merge.end)}</span>`;
    if (it.kind === "stage" && sp && sp.end <= now) finished = `<span>${clock(sp.end)}</span><span class="muted">· ${ago(sp.end)}</span>`;
    const ws = it.writes.length
      ? `<details class="ws"><summary>${it.writes.length} ${it.writes.length === 1 ? "file" : "files"}</summary><ul class="pop-files">${it.writes.map((f) => `<li>${esc(f)}</li>`).join("")}</ul></details>`
      : `<span class="muted">no files</span>`;
    const props = [
      ["status", `<span class="chip ${statusChip[st]}">${esc(st)}</span>`],
      ["worker", it.kind === "task" ? `${esc(it.model)} <span class="muted">build worker</span>` : `orchestrator`],
      ["wave", it.kind === "task" ? `wave ${waveOf(id)}` : `<span class="muted">plan stage</span>`],
      ["spec ids", tags.length ? tags.map((t) => `<span class="label-chip" style="--c:var(${specColour[t]})">${esc(t)}</span>`).join("") : `<span class="muted">none</span>`],
      ["write set", ws, "block"],
      ["created", `<span>${clock(created)}</span><span class="muted">· ${ago(created)}</span>`],
      [it.kind === "task" ? "merged" : "finished", finished],
      ["id", `<span class="mono">${esc(id)}</span>`]
    ];

    const linkRows = (label, ids) => ids.map((d) => {
      const x = items[d], s2 = statusOf(x);
      return `<div class="link-row"><span>${label}</span><button type="button" class="link-btn" data-open="${esc(d)}" style="--c:var(${statusVar[s2]})" aria-label="${label} ${esc(d)}, ${esc(s2)}: ${esc(x.brief.title)}"><i class="dot"></i><span class="mono">${esc(d)}</span><span class="goal">${esc(x.brief.title)}</span></button></div>`;
    }).join("");
    const links = linkRows("Blocked by", it.deps) + linkRows("Blocks", dependents(id));

    const ev = activity(it);
    const acts = ev.length
      ? `<ol class="act">${ev.map((e) => `<li style="--c:var(${e.c})"><i class="dot"></i><div class="ev"><span>${esc(e.text)}</span>${(e.codes || []).map((c) => `<code>${esc(c)}</code>`).join("")}${e.sub ? `<span class="sub">${esc(e.sub)}</span>` : ""}</div>${when(e.t)}</li>`).join("")}</ol>`
      : `<p class="muted">nothing yet</p>`;

    $("dr-body").innerHTML =
      card("Why", `<p>${md(b.why)}</p><p class="dr-ref">Implements <code>${esc(b.designRef.doc)}</code> → ${esc(b.designRef.section)}</p>`) +
      card("Scope", bullets(b.scope)) +
      card("Acceptance", bullets(b.acceptance)) +
      card("Out of scope", bullets(b.outOfScope)) +
      card("Properties", `<dl class="props">${props.map(([k, v, cls]) => `<dt>${k}</dt><dd${cls ? ` class="${cls}"` : ""}>${v}</dd>`).join("")}</dl>`) +
      card("Links", links ? `<div class="links">${links}</div>` : `<p class="muted">no dependencies</p>`) +
      card("Activity", acts) +
      `<details class="dr-card dr-fold"><summary>Tool activity</summary><div style="display:grid;gap:8px">${toolsHtml(toolsOf(it.span))}</div></details>`;
  }

  const drawer = $("drawer"), scrim = $("drawer-scrim");
  let drawerId = null, drawerOpener = null;
  function openDrawer(id, opener) {
    closePop(false);
    if (opener && opener !== drawerOpener) {
      if (drawerOpener) { drawerOpener.classList.remove("sel"); drawerOpener.setAttribute("aria-expanded", "false"); }
      drawerOpener = opener;
      opener.classList.add("sel");
      opener.setAttribute("aria-expanded", "true");
    }
    drawerId = id;
    renderDrawer(id);
    drawer.scrollTop = 0;
    drawer.removeAttribute("inert");
    drawer.classList.add("open");
    scrim.classList.add("open");
    document.documentElement.classList.add("drawer-open");
    drawer.querySelector(".dr-close").focus({ preventScroll: true });
  }
  function closeDrawer() {
    if (!drawerId) return;
    drawerId = null;
    drawer.classList.remove("open");
    scrim.classList.remove("open");
    drawer.setAttribute("inert", "");
    document.documentElement.classList.remove("drawer-open");
    const o = drawerOpener;
    drawerOpener = null;
    if (o) { o.classList.remove("sel"); o.setAttribute("aria-expanded", "false"); if (o.isConnected) o.focus({ preventScroll: true }); }
  }
  drawer.querySelector(".dr-close").addEventListener("click", closeDrawer);
  scrim.addEventListener("pointerdown", (e) => { e.preventDefault(); closeDrawer(); });
  // Following a link keeps the original opener, so closing still returns focus to the card or node.
  $("dr-body").addEventListener("click", (e) => { const l = e.target.closest("[data-open]"); if (l) openDrawer(l.dataset.open); });
  drawer.addEventListener("keydown", (e) => {
    if (e.key !== "Tab") return;
    const f = [...drawer.querySelectorAll("button, summary, [tabindex]:not([tabindex='-1'])")].filter((el) => el.getClientRects().length);
    if (!f.length) return;
    const first = f[0], last = f[f.length - 1];
    if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
    else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
  });

  $("foot").innerHTML =`<span>RunView schema ${view.schemaVersion}</span><span>damage: ${view.damage.length ? view.damage.length + " files" : "none"}</span><span>0 dropped events</span><span>plan text, ids, counts, times and repo-relative paths; no source or transcripts</span>`;
})();
