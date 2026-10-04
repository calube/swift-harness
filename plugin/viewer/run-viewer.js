(function () {
  const M = window.RunViewModel;
  const $ = (id) => document.getElementById(id);
  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  const { fmtTok, fmtTokens, fmtMin, fmtMs, shortRun, sum } = M;
  const verdictChip = (v) => `<span class="chip ${v === "GREEN" ? "ok" : v === "RED" ? "bad" : "warn"}">${esc(v)}</span>`;
  const plural = (n, one, many) => n + " " + (n === 1 ? one : many || one + "s");

  // Errors anywhere on the page are counted where a headless check can read them.
  document.body.dataset.errors = "0";
  const countError = () => { document.body.dataset.errors = String(Number(document.body.dataset.errors) + 1); };
  window.addEventListener("error", countError);
  window.addEventListener("unhandledrejection", countError);

  const pageDamage = [];
  let view = null;
  // Served by `swiftgate view` the page carries no data and fetches it; opened as a file, it is a report.
  let liveMode = false;
  try {
    const text = $("run-view").textContent.trim();
    if (text) view = JSON.parse(text);
    else if (location.protocol !== "file:") liveMode = true;
    else pageDamage.push({ source: "page", reason: "no run data embedded" });
  } catch (error) {
    pageDamage.push({ source: "page", reason: "run data is not JSON: " + error.message });
  }

  // State the page derives from the view on each render.
  let spans = [], wall = 0, t0 = 0, byId = {}, kids = {}, gateBy = {}, taskBy = {};

  // A live run's open spans grow with the clock; a finished run stops at its last event.
  const liveNowMs = () => (liveMode && view.run.state !== "done" ? Date.now() : null);

  function derive() {
    const n = M.normalize(view, liveNowMs());
    spans = n.spans; wall = n.wall || 1; t0 = n.t0;
    byId = {}; kids = {};
    spans.forEach((s) => { byId[s.id] = s; (kids[s.parent] = kids[s.parent] || []).push(s); });
    gateBy = Object.fromEntries(view.gates.map((g) => [g.runId, g]));
    taskBy = Object.fromEntries(view.tasks.map((t) => [t.id, t]));
  }
  const taskSpan = (id) => spans.find((s) => s.phase === "task" && s.task === id);
  const minOf = (iso) => (Date.parse(iso) - t0) / 60000;

  // header
  function renderHeader() {
    const r = view.run;
    $("title").textContent = r.plan || r.id;
    const state = $("state");
    state.textContent = r.state;
    state.className = "chip " + ({ done: "ok", running: "info", halted: "bad" }[r.state] || "plain");
    $("meta").innerHTML = [`run ${esc(r.id)}`, `plan ${esc(r.plan)}`, `preset ${esc(r.preset)}`, `started ${esc(r.startedAt.replace("T", " ").replace("Z", " UTC"))}`].map((x) => `<span>${x}</span>`).join("");
    const roleTok = view.roles.filter((x) => x.tokens).reduce((a, x) => a + sum(x.tokens), 0);
    const taskTok = view.tasks.filter((t) => t.tokens).reduce((a, t) => a + sum(t.tokens), 0);
    const pending = view.tasks.filter((t) => t.tokens == null).length;
    const tests = new Set(view.proofs.map((p) => p.test)).size;
    const proven = new Set(view.proofs.filter((p) => p.outcome === "proven").map((p) => p.test)).size;
    const red = view.gates.filter((g) => g.verdict === "RED").length;
    const taskSpans = spans.filter((s) => s.phase === "task");
    const parallel = taskSpans.reduce((m, s) => Math.max(m, taskSpans.filter((o) => o.start < s.end && s.start < o.end).length), 0);
    const answered = view.halts.filter((h) => h.answer != null).length;
    const stats = [
      [fmtMin(wall), "wall time"],
      [fmtTok(roleTok || taskTok), pending ? `tokens, ${plural(pending, "task")} pending` : "tokens"],
      [plural(view.tasks.length, "task"), `${parallel} in parallel at most`],
      [proven + " / " + tests, "tests proven"],
      [plural(view.gates.length, "gate"), red + " RED"],
      [plural(view.halts.length, "halt"), answered + " answered"]
    ];
    $("stats").innerHTML = stats.map(([b, s]) => `<div class="stat"><b>${esc(b)}</b><span>${esc(s)}</span></div>`).join("");
  }

  // timeline
  const colour = { run: "--bar-phase", task: "--bar-task", worker: "--bar-worker", fix: "--bar-worker", review: "--bar-review", verify: "--bar-gate", merge: "--bar-merge" };
  const barColour = (s) => {
    if (s.phase === "gate" || s.phase === "step") return s.outcome === "red" ? "--bar-red" : "--bar-gate";
    if (s.outcome === "red" || s.outcome === "halted") return "--bar-red";
    return colour[s.phase] || "--bar-phase";
  };
  const scroller = $("tl-scroll");
  const tl = $("tl");
  let zoom = 1;
  let all = {};

  function renderTimeline() {
    const rows = M.lanes(spans, view.gates);
    const pct = (m) => (m / wall) * 100;
    const tick = wall > 120 ? 30 : wall > 60 ? 10 : 5;
    let html = `<div class="tl-row axis"><div class="tl-label" style="font-weight:600;color:var(--muted)">span</div><div class="tl-track">`;
    for (let m = 0; m <= wall; m += tick) html += `<div class="tick" style="left:${pct(m)}%">${m}m</div>`;
    html += `</div></div><div class="grid-lines">`;
    for (let m = tick; m <= wall; m += tick) html += `<i style="left:${pct(m)}%"></i>`;
    html += `</div>`;
    all = {};
    rows.forEach((row) => {
      html += `<div class="tl-row"><div class="tl-label" style="padding-left:${8 + row.depth * 14}px;${row.isTask ? "font-weight:600" : row.depth > 2 ? "color:var(--muted)" : ""}">${esc(row.label)}</div><div class="tl-track">`;
      row.spans.forEach((s) => {
        all[s.id] = s;
        const textColor = s.phase === "merge" ? "var(--bg)" : "var(--bar-text)";
        const dur = M.durationText(s);
        html += `<button class="bar${s.open ? " open" : ""}" data-id="${esc(s.id)}" style="left:${pct(s.start)}%;width:calc(${pct(Math.max(0, s.end - s.start))}% - 2px);background-color:var(${barColour(s)});color:${textColor}" title="${esc(s.label)} · ${esc(dur)}" aria-label="${esc(s.label)}, ${esc(s.phase)}, ${esc(dur)}" aria-haspopup="dialog" aria-expanded="false">${esc(s.label)}</button>`;
      });
      html += `</div></div>`;
    });
    tl.innerHTML = html;
    sizeTrack();
  }

  function sizeTrack() {
    tl.style.width = M.scale(zoom, Math.max(900, scroller.clientWidth)) + "px";
    fitBars();
  }

  function fitBars() {
    tl.querySelectorAll(".bar").forEach((b) => {
      const s = all[b.dataset.id];
      b.classList.toggle("notext", !M.labelFits(s.label, b.clientWidth));
    });
  }

  // span popover
  const pop = $("pop");
  const sheet = window.matchMedia("(max-width: 520px)");
  let openAnchor = null;

  function toolsHtml(t, filesLabel = "Files touched") {
    if (!t) return `<p class="sub">no tool activity recorded</p>`;
    const calls = t.calls.reduce((a, c) => a + c.count, 0) + (t.otherCount || 0);
    const shown = t.files.slice(0, 6);
    const more = t.files.length - shown.length;
    const files = t.files.length
      ? `<ul class="pop-files">${shown.map((f) => `<li>${esc(f)}</li>`).join("")}${more > 0 ? `<li class="more">+${more} more</li>` : ""}</ul>`
      : `<p class="sub">no files touched</p>`;
    const chips = t.calls.map((c) => `<span class="chip plain num" title="${esc(fmtMs(c.ms))}">${esc(c.tool)} ${c.count}</span>`)
      .concat(t.otherCount ? [`<span class="chip plain num">other ${t.otherCount}</span>`] : []);
    return `${chips.length ? `<div class="tags">${chips.join("")}</div>` : ""}
      <p class="sub num">${calls} calls · ${fmtMs(t.ms)} tool time</p>
      <h4>${esc(filesLabel)} (${t.files.length})</h4>${files}
      ${t.droppedPaths ? `<p class="sub">${plural(t.droppedPaths, "path")} dropped: outside the repository</p>` : ""}`;
  }

  function place() {
    if (!openAnchor) return;
    if (sheet.matches) { pop.style.left = ""; pop.style.top = ""; return; }
    const r = openAnchor.getBoundingClientRect();
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

  // Anchors a popover of label and value rows to any element; modules use it through runViewer.
  function openPopover(anchor, rows, title, extraHtml = "", focus = true) {
    if (openAnchor) closePop(false);
    openAnchor = anchor;
    anchor.classList.add("sel");
    anchor.setAttribute("aria-expanded", "true");
    $("pop-title").textContent = title != null ? title : anchor.getAttribute("aria-label") || "";
    $("pop-body").innerHTML = `<dl>${rows.map(([k, v, html]) => `<dt>${esc(k)}</dt><dd>${html ? v : esc(v)}</dd>`).join("")}</dl>${extraHtml}`;
    pop.hidden = false;
    place();
    if (focus) pop.querySelector(".pop-close").focus({ preventScroll: true });
  }

  function openSpan(bar, focus = true) {
    const s = all[bar.dataset.id];
    const outcome = s.outcome ? (s.outcome === "red" ? "RED" : s.outcome === "ok" ? "GREEN" : s.outcome) : null;
    const rows = [
      ["phase", s.tier ? `${s.tier} ${s.phase}` : s.phase],
      ["span", s.phase === "step" ? s.parent : s.id, `<span class="mono">${esc(s.phase === "step" ? s.parent : s.id)}</span>`],
      ["task", s.task || "none"],
      ["start", "+" + fmtMin(s.start)],
      ["duration", M.durationText(s) + (s.approximate ? " (approximate)" : "")],
      ["gate run", s.gateRun || "none", s.gateRun ? `<span class="mono">${esc(s.gateRun)}</span>` : null],
      ["outcome", outcome || "none", outcome ? verdictChip(outcome) : null]
    ];
    const tools = s.phase === "step" ? null : M.toolSummary(spans, s.id);
    openPopover(bar, rows, s.label, `<div class="pop-tools"><h4>Tools</h4>${toolsHtml(tools)}</div>`, focus);
  }

  function closePop(restoreFocus = true) {
    if (!openAnchor) return;
    const anchor = openAnchor;
    openAnchor = null;
    pop.hidden = true;
    anchor.classList.remove("sel");
    anchor.setAttribute("aria-expanded", "false");
    if (restoreFocus && anchor.isConnected) anchor.focus({ preventScroll: true });
  }

  tl.addEventListener("click", (e) => {
    const b = e.target.closest(".bar");
    if (!b) return;
    if (b === openAnchor) closePop(); else openSpan(b);
  });
  pop.querySelector(".pop-close").addEventListener("click", () => closePop());
  document.addEventListener("keydown", (e) => {
    if (e.key !== "Escape") return;
    if (drawerId) { e.preventDefault(); closeDrawer(); } else if (openAnchor) { e.preventDefault(); closePop(); }
  });
  document.addEventListener("pointerdown", (e) => {
    if (openAnchor && !pop.contains(e.target) && !openAnchor.contains(e.target)) closePop();
  });
  window.addEventListener("scroll", place, { capture: true, passive: true });
  window.addEventListener("resize", () => { if (view) sizeTrack(); place(); });
  sheet.addEventListener("change", place);

  // zoom: scale the track and keep the time at the middle of the visible track in view
  const zoomBtns = [...document.querySelectorAll("#zoom button")];
  function setZoom(z) {
    const labelW = tl.querySelector(".tl-label").offsetWidth;
    const mid = (labelW + scroller.clientWidth) / 2;
    const f = (scroller.scrollLeft + mid - labelW) / (tl.offsetWidth - labelW);
    zoom = z;
    sizeTrack();
    scroller.scrollLeft = labelW + f * (tl.offsetWidth - labelW) - mid;
    zoomBtns.forEach((b) => b.setAttribute("aria-pressed", String(Number(b.dataset.z) === z)));
    place();
  }
  zoomBtns.forEach((b) => b.addEventListener("click", () => setZoom(Number(b.dataset.z))));

  // spec mapping
  function renderSpec() {
    $("spec").innerHTML = `<thead><tr><th>requirement</th><th>tasks</th><th>merged commits</th><th>merge gate</th></tr></thead><tbody>` +
      view.spec.map((q) => {
        const ts = q.tasks.map((id) => taskBy[id]).filter(Boolean);
        const verdicts = ts.map((t) => (gateBy[t.mergeGateRun] ? gateBy[t.mergeGateRun].verdict : null));
        const v = !q.tasks.length ? `<span class="chip warn">uncovered</span>`
          : verdicts.includes("RED") ? verdictChip("RED")
          : verdicts.length && verdicts.every((x) => x === "GREEN") ? verdictChip("GREEN")
          : `<span class="chip plain">not merged</span>`;
        return `<tr><td><span class="mono">${esc(q.id)}</span><div class="sub">${esc(q.title)}</div></td>
          <td><div class="tags">${q.tasks.map((t) => `<span class="tag">${esc(t)}</span>`).join("")}</div></td>
          <td><div class="tags">${ts.flatMap((t) => t.commits).map((c) => `<span class="tag">${esc(c)}</span>`).join("")}</div></td>
          <td>${v}</td></tr>`;
      }).join("") + `</tbody>`;
  }

  // proof: the assertion's file, line and kind only; a report never carries source
  const outcomeText = { proven: ["failed", "ok", "proven"], "passes-reverted": ["passed", "bad", "not proven"], "compile-only": ["didn't compile", "warn", "not proven"], crashed: ["crashed", "warn", "not proven"], skipped: ["skipped", "warn", "not proven"] };
  function renderProof() {
    $("proof").innerHTML = `<thead><tr><th>test</th><th>with the change reverted</th><th>assertion</th></tr></thead><tbody>` +
      view.proofs.map((p) => {
        const [txt, cls, label] = outcomeText[p.outcome] || [p.outcome, "warn", "unknown"];
        const a = p.assertion ? `<span class="mono" title="${esc(p.assertion.file)}">${esc(p.assertion.file.split("/").pop())}:${esc(p.assertion.line)}</span><div class="sub">#${esc(p.assertion.kind)}</div>` : `<span class="sub">none failed</span>`;
        return `<tr><td><span class="mono">${esc(p.test)}</span><div class="sub">${esc(p.task)} · base ${esc(p.proofBase || "none")} · run <span class="mono" title="${esc(p.gateRun)}">${esc(shortRun(p.gateRun))}</span></div></td>
          <td><span class="chip ${cls}">${esc(label)}</span><div class="sub">${esc(txt)}</div></td><td>${a}</td></tr>`;
      }).join("") + `</tbody>`;
  }

  // tokens
  function tokRows(items, labelKey, timeFn) {
    const max = Math.max(1, ...items.filter((x) => x.tokens).map((x) => sum(x.tokens)));
    return items.map((x) => {
      const t = x.tokens, w = (n) => (n / max) * 100;
      const bar = t
        ? `<div class="tok-bar" title="input ${fmtTok(t.input)}, cache read ${fmtTok(t.cacheRead)}, cache write ${fmtTok(t.cacheWrite)}, output ${fmtTok(t.output)}">
          <i style="width:${w(t.input)}%;background:var(--accent)"></i><i style="width:${w(t.cacheRead)}%;background:var(--bar-review)"></i><i style="width:${w(t.cacheWrite)}%;background:var(--warn)"></i><i style="width:${w(t.output)}%;background:var(--ok)"></i>
        </div>`
        : `<div class="tok-bar" title="tokens arrive when the worker's transcript is ingested"></div>`;
      const time = timeFn ? timeFn(x) : "";
      return `<div class="tok-row"><span class="mono">${esc(x[labelKey])}</span>${bar}<span class="num" style="text-align:right">${fmtTokens(t)}${time ? `<div class="sub" style="color:var(--muted);font-size:11px">${esc(time)}</div>` : ""}</span></div>`;
    }).join("");
  }
  function renderTokens() {
    $("tokens").innerHTML = tokRows(view.tasks, "id", (t) => { const s = taskSpan(t.id); return s ? M.durationText(s) : ""; });
    $("roles").innerHTML = tokRows(view.roles, "role");
  }

  // gates
  function renderGates() {
    $("gates").innerHTML = view.gates.map((g) => {
      const rules = Object.entries(g.ruleCounts || {});
      return `<div class="gate"><div class="gate-top">${verdictChip(g.verdict)}<span class="mono">${esc(g.runId)}</span></div>
        <div class="sub" style="color:var(--muted);font-size:12px">${esc(g.task || "no task")} · swiftgate ${esc(g.command)} · ${fmtMs(g.ms)} · ${g.tests.passed} passed, ${g.tests.failed} failed, ${g.tests.skipped} skipped</div>
        <div class="steps">${g.steps.map((s) => `<span class="step ${s.verdict === "RED" ? "red" : ""}">${esc(s.tier)} ${esc(s.step)} ${fmtMs(s.ms)}</span>`).join("")}</div>
        ${rules.length ? `<div class="tags">${rules.map(([k, n]) => `<span class="tag">${esc(k)} ${n}</span>`).join("")}</div>` : ""}</div>`;
    }).join("");
  }

  // task drawer: opened from a board card, a graph node or a link, it reads like a ticket
  const statusChip = { pending: "plain", "in-progress": "info", done: "ok", blocked: "bad", "needs-replan": "warn", abandoned: "bad" };
  const statusVar = { pending: "--muted", "in-progress": "--accent", done: "--ok", blocked: "--bad", "needs-replan": "--warn", abandoned: "--bad" };
  const clock = (ms) => { const d = new Date(ms); return String(d.getUTCHours()).padStart(2, "0") + ":" + String(d.getUTCMinutes()).padStart(2, "0") + " UTC"; };
  const nowMs = () => t0 + wall * 60000;
  const ago = (ms) => { const d = (nowMs() - ms) / 60000; return d < 1 ? "just now" : d < 60 ? Math.round(d) + "m ago" : Math.floor(d / 60) + "h ago"; };
  const when = (ms) => `<time title="+${fmtMin((ms - t0) / 60000)} · ${clock(ms)}">${ago(ms)}</time>`;
  const md = (txt) => esc(txt).replace(/`([^`]+)`/g, "<code>$1</code>");
  const bullets = (xs) => `<ul class="dr-list">${xs.map((x) => `<li>${md(x)}</li>`).join("")}</ul>`;
  const card = (label, body) => `<section class="dr-card"><h4>${label}</h4>${body}</section>`;

  function renderDrawer(id) {
    const t = taskBy[id], b = t.brief;
    $("dr-id").textContent = t.id;
    $("dr-status").className = "chip " + (statusChip[t.status] || "plain");
    $("dr-status").textContent = t.status;
    $("dr-title").textContent = b ? b.title : t.id;
    const specColour = Object.fromEntries(view.spec.map((q, i) => [q.id, `--label-${(i % 5) + 1}`]));
    const writes = t.writes || [];
    const ws = writes.length
      ? `<details class="ws"><summary>${plural(writes.length, "file")}</summary><ul class="pop-files">${writes.map((f) => `<li>${esc(f)}</li>`).join("")}</ul></details>`
      : `<span class="muted">no files</span>`;
    const merged = t.mergedAt
      ? `${(t.commits || []).map((c) => `<code>${esc(c)}</code>`).join("")}<span class="muted">${clock(Date.parse(t.mergedAt))} · ${ago(Date.parse(t.mergedAt))}</span>`
      : `<span class="muted">not yet</span>`;
    const created = t.createdAt ? `<span>${clock(Date.parse(t.createdAt))}</span><span class="muted">· ${ago(Date.parse(t.createdAt))}</span>` : `<span class="muted">unknown</span>`;
    const covers = t.covers || [];
    const props = [
      ["status", `<span class="chip ${statusChip[t.status] || "plain"}">${esc(t.status)}</span>`],
      ["worker", `${esc(t.model)} <span class="muted">build worker</span>`],
      ["wave", `wave ${M.waveOf(view, id)}`],
      ["spec ids", covers.length ? covers.map((c) => `<span class="label-chip" style="--c:var(${specColour[c] || "--muted"})">${esc(c)}</span>`).join("") : `<span class="muted">none</span>`],
      ["write set", ws, "block"],
      ["gate", t.gate ? esc(t.gate) : `<span class="muted">none</span>`],
      ["created", created],
      ["merged", merged],
      ["id", `<span class="mono">${esc(id)}</span>`]
    ];

    const linkRows = (label, ids) => ids.map((d) => {
      const x = taskBy[d];
      if (!x) return `<div class="link-row"><span>${label}</span><span class="mono">${esc(d)}</span></div>`;
      const goal = x.brief ? x.brief.title : x.status;
      return `<div class="link-row"><span>${label}</span><button type="button" class="link-btn" data-open="${esc(d)}" style="--c:var(${statusVar[x.status] || "--muted"})" aria-label="${label} ${esc(d)}, ${esc(x.status)}: ${esc(goal)}"><i class="dot"></i><span class="mono">${esc(d)}</span><span class="goal">${esc(goal)}</span></button></div>`;
    }).join("");
    const links = linkRows("Blocked by", t.deps || []) + linkRows("Blocks", M.blocks(view, id));

    const ev = M.activity(view, id);
    const acts = ev.length
      ? `<ol class="act">${ev.map((e) => `<li style="--c:var(${e.c})"><i class="dot"></i><div class="ev"><span>${esc(e.text)}</span>${(e.codes || []).map((c) => `<code>${esc(c)}</code>`).join("")}${e.sub ? `<span class="sub">${esc(e.sub)}</span>` : ""}</div>${when(e.at)}</li>`).join("")}</ol>`
      : `<p class="muted">nothing yet</p>`;
    const ts = taskSpan(id);

    $("dr-body").innerHTML =
      (b ? card("Why", `<p>${md(b.why)}</p>${b.designRef ? `<p class="dr-ref">Implements design ${esc(b.designRef)}</p>` : ""}`) +
        card("Scope", bullets(b.scope)) +
        card("Acceptance", bullets(b.acceptance)) +
        card("Out of scope", bullets(b.outOfScope)) : "") +
      card("Properties", `<dl class="props">${props.map(([k, v, cls]) => `<dt>${k}</dt><dd${cls ? ` class="${cls}"` : ""}>${v}</dd>`).join("")}</dl>`) +
      card("Links", links ? `<div class="links">${links}</div>` : `<p class="muted">no dependencies</p>`) +
      card("Activity", acts) +
      `<details class="dr-card dr-fold"><summary>Tool activity</summary><div style="display:grid;gap:8px">${toolsHtml(ts ? M.toolSummary(spans, ts.id) : null)}</div></details>`;
  }

  const drawer = $("drawer"), scrim = $("drawer-scrim");
  let drawerId = null, drawerOpener = null;
  // With no opener given, focus returns on close to whatever had it when the drawer opened.
  function openTaskDrawer(id, opener) {
    if (!taskBy[id]) return false;
    closePop(false);
    const from = opener || (drawerId ? null : document.activeElement);
    if (from && from !== drawerOpener && from !== document.body) {
      if (drawerOpener) { drawerOpener.classList.remove("sel"); drawerOpener.setAttribute("aria-expanded", "false"); }
      drawerOpener = from;
      if (opener) { opener.classList.add("sel"); opener.setAttribute("aria-expanded", "true"); }
    }
    drawerId = id;
    renderDrawer(id);
    drawer.scrollTop = 0;
    drawer.removeAttribute("inert");
    drawer.classList.add("open");
    scrim.classList.add("open");
    document.documentElement.classList.add("drawer-open");
    drawer.querySelector(".dr-close").focus({ preventScroll: true });
    return true;
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
  // Following a link keeps the original opener, so closing still returns focus to it.
  $("dr-body").addEventListener("click", (e) => { const l = e.target.closest("[data-open]"); if (l) openTaskDrawer(l.dataset.open); });
  drawer.addEventListener("keydown", (e) => {
    if (e.key !== "Tab") return;
    const f = [...drawer.querySelectorAll("button, summary, [tabindex]:not([tabindex='-1'])")].filter((el) => el.getClientRects().length);
    if (!f.length) return;
    const first = f[0], last = f[f.length - 1];
    if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
    else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
  });

  // footer: every damage row is a visible line, never a silent gap
  function renderFooter() {
    const damage = (view ? view.damage : []).concat(pageDamage);
    $("foot").innerHTML = `<span>RunView schema ${view ? esc(view.schemaVersion) : "none"}</span><span>damage: ${damage.length ? damage.length : "none"}</span><span>plan text, ids, counts, times and repo-relative paths; no source or transcripts</span>` +
      damage.map((d) => `<span class="damage-line">${esc(d.source)}: ${esc(d.reason)}</span>`).join("");
  }

  // Optional modules (board, graph) render into their own hidden panel. One that throws is shown
  // as a damage line and its panel stays hidden, so it can't blank the core regions.
  const modules = new Map();
  function runModule(name, step) {
    const mod = modules.get(name);
    const mount = document.querySelector(`[data-module="${CSS.escape(name)}"]`);
    if (!mod || !mount || !view) return;
    try {
      if (step === "render") mod.render(view, mount); else if (mod.apply) mod.apply(view);
      mount.hidden = false;
    } catch (error) {
      mount.hidden = true;
      pageDamage.push({ source: "module " + name, reason: String(error && error.message ? error.message : error) });
      renderFooter();
    }
  }
  function register(name, mod) {
    modules.set(name, mod);
    runModule(name, "render");
  }

  // now strip: live mode only, 1 card per running task with stall and halt badges
  let strip = null;
  function ensureStrip() {
    if (strip) return strip;
    strip = document.createElement("section");
    strip.className = "panel now";
    strip.id = "now";
    strip.setAttribute("aria-label", "Now");
    strip.innerHTML = `<div class="head"><h2>Now</h2><span class="now-note" id="now-note"></span></div><div class="now-cards" id="now-cards" role="list"></div>`;
    document.querySelector(".wrap > .panel").after(strip);
    return strip;
  }
  const stageLabel = (w) => {
    if (w.phase === "gate") { const g = w.gateRun && gateBy[w.gateRun]; return g ? "gate " + M.gateTier(g.command) : "gate"; }
    return w.phase === "task" ? "starting" : w.phase.replace(/-/g, " ");
  };
  const age = (msAgo) => (msAgo < 60000 ? Math.max(0, Math.round(msAgo / 1000)) + "s ago" : fmtMs(msAgo) + " ago");

  function renderNow() {
    if (!liveMode) return;
    ensureStrip();
    const now = Date.now();
    // Without the preset's stall_min there is nothing to measure a stall against, so the strip says so.
    const stallMin = typeof view.run.stallMin === "number" ? view.run.stallMin : null;
    const cards = M.workers(view, now, stallMin == null ? Infinity : stallMin);
    const runHalts = M.openHalts(view).filter((h) => h.task == null);
    $("now-note").innerHTML = (stallMin == null ? `<span class="sub">stall watch off: the run names no stall_min</span>` : `<span class="sub">stalled after ${plural(stallMin, "minute")} quiet</span>`) +
      runHalts.map((h) => `<span class="chip bad">run halted: ${esc(h.reason)}</span>`).join("");
    $("now-cards").innerHTML = cards.length ? cards.map((w) => `<div class="now-card${w.halted ? " halted" : w.stalled ? " stalled" : ""}" role="listitem" data-task="${esc(w.task)}">
        <div class="now-top"><b class="mono">${esc(w.task)}</b>${w.halted ? `<span class="chip bad" title="${esc(w.halt.reason)}">halted</span>` : ""}${w.stalled ? `<span class="chip warn">stalled</span>` : ""}</div>
        <div class="now-stage"><span>${esc(stageLabel(w))}</span><span class="num">${esc(fmtMs(w.elapsedMs))}</span></div>
        <div class="sub num">last event ${w.lastEventMs == null ? "none" : esc(age(now - w.lastEventMs))}</div>
      </div>`).join("") : `<p class="sub">idle: no task running</p>`;
  }

  function render() {
    derive();
    renderHeader();
    renderNow();
    renderTimeline();
    renderSpec();
    renderProof();
    renderTokens();
    renderGates();
    renderFooter();
  }

  // Merges a partial RunView by id and redraws; live mode calls this on each poll.
  // A redraw keeps what the reader had: the open span popover, the focused bar, and the drawer's
  // focus and folds, so a 1 s poll never pulls them away.
  function apply(partial) {
    view = M.apply(view, partial);
    const active = document.activeElement;
    const popSpan = openAnchor && openAnchor.classList.contains("bar") ? openAnchor.dataset.id : null;
    const popFocus = pop.contains(active);
    const barFocus = active && active.classList && active.classList.contains("bar") ? active.dataset.id : null;
    const drawerFocusables = () => [...drawer.querySelectorAll("#dr-body button, #dr-body summary")];
    const drawerFocus = drawerId ? drawerFocusables().indexOf(active) : -1;
    const folds = drawerId ? [...drawer.querySelectorAll("#dr-body details")].map((d) => d.open) : [];
    closePop(false);
    render();
    modules.forEach((_, name) => runModule(name, "apply"));
    const bar = (id) => (id ? tl.querySelector(`.bar[data-id="${CSS.escape(id)}"]`) : null);
    if (barFocus && bar(barFocus)) bar(barFocus).focus({ preventScroll: true });
    if (popSpan && bar(popSpan)) openSpan(bar(popSpan), popFocus);
    if (drawerId) {
      renderDrawer(drawerId);
      drawer.querySelectorAll("#dr-body details").forEach((d, i) => { if (folds[i]) d.open = true; });
      if (drawerFocus >= 0 && drawerFocusables()[drawerFocus]) drawerFocusables()[drawerFocus].focus({ preventScroll: true });
    }
  }

  // live mode: fetch the whole view once, then merge each change set polled after its cursor
  const POLL_MS = 1000;
  let polls = 0, pollFailures = 0;
  async function fetchJSON(path) {
    const response = await fetch(path, { cache: "no-store" });
    if (!response.ok) throw new Error(`${path.split("?")[0]} answered ${response.status}`);
    return response.json();
  }
  function showLiveError(message) {
    let line = $("live-error");
    if (!line) {
      line = document.createElement("div");
      line.id = "live-error";
      line.className = "live-error";
      line.setAttribute("role", "status");
      document.querySelector(".wrap > .panel").appendChild(line);
    }
    line.textContent = message || "";
    line.hidden = !message;
  }
  async function poll() {
    try {
      if (!view) {
        view = await fetchJSON("/view.json");
        render();
      } else {
        apply(await fetchJSON("/changes?after=" + encodeURIComponent(view.cursor)));
      }
      polls++;
      document.body.dataset.polls = String(polls);
      showLiveError(null);
    } catch (error) {
      pollFailures++;
      document.body.dataset.pollFailures = String(pollFailures);
      showLiveError(`live updates paused: ${error.message}; retrying every second`);
    }
    setTimeout(poll, POLL_MS);
  }

  window.runViewer = {
    register,
    openPopover: (anchor, rows, title) => openPopover(anchor, rows.map(([k, v]) => [k, v]), title),
    openTaskDrawer,
    apply
  };

  if (liveMode) {
    document.body.dataset.live = "on";
    const mode = document.querySelector(".wrap > .panel .head .chip.plain:not(#state)");
    if (mode) mode.textContent = "Live";
    renderFooter();
    poll();
  } else if (view) render(); else renderFooter();
})();
