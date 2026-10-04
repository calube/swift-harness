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
    const box = M.timeBoxText(r);
    $("meta").innerHTML = [`run ${esc(r.id)}`, `plan ${esc(r.plan)}`, `preset ${esc(r.preset)}`, `started ${esc(r.startedAt.replace("T", " ").replace("Z", " UTC"))}`].concat(box ? [esc(box)] : []).map((x) => `<span>${x}</span>`).join("");
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
  // What the open popover shows: "span", "task", or "other" for a module's rows.
  let popKind = null;

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

  // Why a gate run, a stage or a task failed. The popover shows a few lines, each message cut;
  // the task drawer shows every line the view carries, whole.
  const POP_LINES = 3, POP_MESSAGE = 140;
  const stageText = { task: "task gate", worker: "worker's gate", merge: "merge gate", final: "final gate" };
  const blockText = {
    "gate-red": "its last gate run was RED",
    "return-rejected": "build check-return rejected its return",
    "return-not-stored": "no return of it was stored: none came back, or a check-return that records nothing rejected it",
    halt: "a halt stopped it"
  };
  function failureHeadline(g) {
    const f = g.failure;
    const tiers = f.tiers.length ? f.tiers.join(", ") + " failed" : g.verdict;
    return [tiers, f.checkTier ? f.checkTier + " tier" : null, f.stage ? stageText[f.stage] : null].filter(Boolean).join(" · ");
  }
  function findingHtml(x, max) {
    const at = M.location(x.file, x.line);
    const message = max ? M.clip(x.message, max) : x.message;
    const cut = !max && x.truncated ? ` <span class="muted">(cut; the report holds the rest)</span>` : "";
    return `<li><div class="fail-head"><span class="chip ${x.severity === "blocker" || x.severity === "major" ? "bad" : "warn"}">${esc(x.severity)}</span><code>${esc(x.rule)}</code>${at ? `<span class="mono">${esc(at)}</span>` : ""}</div><div class="fail-msg">${esc(message)}${cut}</div></li>`;
  }
  function testHtml(t) {
    const at = M.location(t.file, t.line);
    const how = t.proof ? "not proven: " + t.proof : "failed" + (t.tier ? " in " + t.tier : "");
    return `<li><div class="fail-head"><span class="mono">${esc(t.test)}</span></div><div class="fail-msg">${esc(how)}${at ? ` at <span class="mono">${esc(at)}</span>` : ""}</div></li>`;
  }
  function more(n, where) { return n > 0 ? `<li class="more">+${n} more ${where}</li>` : ""; }
  // 1 gate run's failure; `full` is the drawer's form.
  function gateFailureHtml(g, full) {
    const f = g.failure;
    const n = full ? Infinity : POP_LINES;
    const findings = f.findings.slice(0, n), tests = f.failedTests.slice(0, n);
    const hiddenF = f.findings.length - findings.length, hiddenT = f.failedTests.length - tests.length;
    const counts = g.tests ? `<p class="sub num">${g.tests.passed} passed, ${g.tests.failed} failed, ${g.tests.skipped} skipped</p>` : "";
    const rules = !f.findings.length && Object.keys(g.ruleCounts || {}).length
      ? `<div class="tags">${Object.entries(g.ruleCounts).map(([k, v]) => `<span class="tag">${esc(k)} ${v}</span>`).join("")}</div>` : "";
    const where = full ? "in the report" : "in the task drawer";
    return `<p class="fail-line"><span class="chip bad">${esc(g.verdict)}</span> ${esc(failureHeadline(g))}</p>${counts}
      ${findings.length ? `<h4>Gating findings</h4><ul class="fail-list">${findings.map((x) => findingHtml(x, full ? 0 : POP_MESSAGE)).join("")}${more(hiddenF, where)}${more(f.moreFindings, "in the report")}</ul>` : rules}
      ${tests.length ? `<h4>Failing tests</h4><ul class="fail-list">${tests.map(testHtml).join("")}${more(hiddenT, where)}${more(f.moreFailedTests, "in the report")}</ul>` : ""}
      <p class="sub">run <span class="mono">${esc(g.runId)}</span></p>
      <p class="sub">${f.report ? `report <code>${esc(f.report)}</code>` : "its report.json isn't in any live checkout"} · <code>${esc(f.command)}</code></p>`;
  }
  // What build check-return said about a rejected return; `full` is the drawer's form.
  function rejectionHtml(r, full) {
    const shown = r.findings.slice(0, full ? Infinity : POP_LINES);
    const hidden = r.findings.length - shown.length;
    const rows = shown.map((x) => `<li><div class="fail-head"><code>${esc(x.rule)}</code></div><div class="fail-msg">${esc(full ? x.message : M.clip(x.message, POP_MESSAGE))}${full && x.truncated ? ` <span class="muted">(cut)</span>` : ""}</div></li>`);
    const list = shown.length
      ? `<ul class="fail-list">${rows.join("")}${more(hidden, "in the task drawer")}${more(r.moreFindings, "in check-return's output")}</ul>`
      : r.rules.length ? `<div class="tags">${r.rules.map((k) => `<span class="tag">${esc(k)}</span>`).join("")}</div>` : "";
    return `<p class="sub">check-return ${esc(r.verdict)}${r.fix ? " on the fixer's return" : ""}: ${esc(full ? r.message : M.clip(r.message, POP_MESSAGE))}</p>${list}`;
  }
  function blockHtml(b, gateOf, full) {
    const g = b.gateRun ? gateOf(b.gateRun) : null;
    return `<p class="fail-line"><span class="chip bad">stopped</span> at ${esc(clock(Date.parse(b.at)))}${b.cause ? `: ${esc(blockText[b.cause] || b.cause)}` : ""}</p>
      ${b.rejection ? rejectionHtml(b.rejection, full) : ""}
      ${b.halt ? `<p class="sub">halt raised: ${esc(b.halt)}</p>` : ""}
      ${b.gateRun ? `<p class="sub">last gate run <span class="mono">${esc(b.gateRun)}</span> ${g ? esc(g.verdict) : ""}</p>` : `<p class="sub">no gate run</p>`}`;
  }
  // The popover's "Why it failed" section for a span; empty when nothing explains it.
  function spanFailureHtml(s) {
    const why = M.failureOf(view, s);
    if (!why) return "";
    const parts = [];
    if (why.block) parts.push(blockHtml(why.block, why.gateOf, false));
    if (why.gate) parts.push(gateFailureHtml(why.gate, false));
    why.halts.forEach((h) => {
      const g = h.gateRun ? why.gateOf(h.gateRun) : null;
      parts.push(`<p class="fail-line"><span class="chip bad">halted</span> ${esc(h.task || "the run")}: ${esc(h.reason)}</p>${g && g.failure ? gateFailureHtml(g, false) : ""}`);
    });
    const task = s.task && taskBy[s.task] ? `<button type="button" class="link-btn" data-open-task="${esc(s.task)}">Open ${esc(s.task)} for every line</button>` : "";
    const heading = why.gate || why.halts.length ? "Why it failed" : "Why it stopped";
    return `<div class="pop-fail" role="group" aria-label="${heading}"><h4>${heading}</h4>${parts.join("")}${task}</div>`;
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
    $("pop-body").innerHTML = `<dl>${rows.map(([k, v, html]) => `<dt>${esc(k)}</dt><dd>${html != null ? html : esc(v)}</dd>`).join("")}</dl>${extraHtml}`;
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
    openPopover(bar, rows, s.label, `${spanFailureHtml(s)}<div class="pop-tools"><h4>Tools</h4>${toolsHtml(tools)}</div>`, focus);
    popKind = "span";
  }

  function closePop(restoreFocus = true) {
    if (!openAnchor) return;
    const anchor = openAnchor;
    openAnchor = null;
    popKind = null;
    pop.hidden = true;
    pinned = false;
    anchor.classList.remove("sel");
    anchor.setAttribute("aria-expanded", "false");
    if (restoreFocus && anchor.isConnected) {
      restoring = true;
      anchor.focus({ preventScroll: true });
      restoring = false;
    }
  }

  // Hovering or focusing a bar previews its popover without moving focus; a click or Enter pins
  // it and moves focus in. A preview closes when the pointer or focus leaves its bar.
  let pinned = false, restoring = false;
  tl.addEventListener("click", (e) => {
    const b = e.target.closest(".bar");
    if (!b) return;
    if (b === openAnchor && pinned) { closePop(); return; }
    openSpan(b);
    pinned = true;
  });
  const preview = (b) => { if (b && b !== openAnchor && !pinned && !restoring) { openSpan(b, false); pinned = false; } };
  tl.addEventListener("focusin", (e) => preview(e.target.closest(".bar")));
  tl.addEventListener("mouseover", (e) => preview(e.target.closest(".bar")));
  tl.addEventListener("focusout", (e) => {
    if (pinned || !openAnchor || e.target !== openAnchor) return;
    if (!e.relatedTarget || (!pop.contains(e.relatedTarget) && !e.relatedTarget.closest(".bar"))) closePop(false);
  });
  tl.addEventListener("mouseout", (e) => {
    const b = e.target.closest(".bar");
    if (pinned || !b || b !== openAnchor || document.activeElement === b) return;
    if (!e.relatedTarget || (!pop.contains(e.relatedTarget) && e.relatedTarget.closest(".bar") !== b)) closePop(false);
  });
  pop.addEventListener("click", (e) => {
    const l = e.target.closest("[data-open-task]");
    if (l) openTaskDrawer(l.dataset.openTask, openAnchor);
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
    $("spec-table").innerHTML = `<thead><tr><th>requirement</th><th>tasks</th><th>merged commits</th><th>merge gate</th></tr></thead><tbody>` +
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
    $("token-rows").innerHTML = tokRows(view.tasks, "id", (t) => { const s = taskSpan(t.id); return s ? M.durationText(s) : ""; });
    $("roles").innerHTML = tokRows(view.roles, "role");
  }

  // gates
  function renderGates() {
    $("gate-list").innerHTML = view.gates.map((g) => {
      const rules = Object.entries(g.ruleCounts || {});
      return `<div class="gate"><div class="gate-top">${verdictChip(g.verdict)}<span class="mono">${esc(g.runId)}</span></div>
        <div class="sub" style="color:var(--muted);font-size:12px">${esc(g.task || "no task")} · swiftgate ${esc(g.command)} · ${fmtMs(g.ms)}${g.tests ? ` · ${g.tests.passed} passed, ${g.tests.failed} failed, ${g.tests.skipped} skipped` : ""}</div>
        <div class="steps">${g.steps.map((s) => `<span class="step ${s.verdict === "RED" ? "red" : ""}">${esc(s.tier)} ${esc(s.step)} ${fmtMs(s.ms)}</span>`).join("")}</div>
        ${rules.length ? `<div class="tags">${rules.map(([k, n]) => `<span class="tag">${esc(k)} ${n}</span>`).join("")}</div>` : ""}
        ${g.failure ? `<div class="gate-fail"><p class="sub">${esc(failureHeadline(g))}</p>${g.failure.findings.length ? `<ul class="fail-list">${g.failure.findings.slice(0, POP_LINES).map((x) => findingHtml(x, POP_MESSAGE)).join("")}${more(g.failure.findings.length - Math.min(POP_LINES, g.failure.findings.length) + g.failure.moreFindings, "")}</ul>` : ""}</div>` : ""}</div>`;
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
    const redGates = view.gates.filter((g) => g.task === id && g.failure);
    const gateOf = (rid) => gateBy[rid] || null;
    const failed = t.blocked || redGates.length
      ? card(redGates.length ? "Why it failed" : "Why it stopped", `${t.blocked ? blockHtml(t.blocked, gateOf, true) : ""}${redGates.map((g) => `<div class="dr-fail">${gateFailureHtml(g, true)}</div>`).join("")}`)
      : "";

    $("dr-body").innerHTML = failed +
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
    const o = reconnect(drawerOpener);
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

  // An anchor a redraw replaced: the element now in its place, found by its class and task id.
  function reconnect(el) {
    if (!el || el.isConnected) return el;
    const id = el.dataset && el.dataset.task;
    const cls = el.classList && el.classList[0];
    return id && cls ? document.querySelector(`.${CSS.escape(cls)}[data-task="${CSS.escape(id)}"]`) : null;
  }

  // Each task's board lane. Without the board module, a lane comes from the status alone.
  const LANE_ORDER = ["queued", "building", "gating", "review", "merged", "blocked"];
  const statusLane = (status) => (status === "done" ? "merged" : ["blocked", "needs-replan", "abandoned"].includes(status) ? "blocked" : status === "in-progress" ? "building" : "queued");
  function laneMap() {
    const out = {};
    if (window.RunViewBoard) {
      const cols = window.RunViewBoard.columns(view);
      Object.keys(cols).forEach((lane) => cols[lane].forEach((c) => { out[c.id] = lane; }));
    } else view.tasks.forEach((t) => { out[t.id] = statusLane(t.status); });
    return out;
  }

  // Overview's compact board: the count in each lane, then 1 row per task that opens its details.
  let taskTableHtml = null;
  function renderTaskTable() {
    const lanes = laneMap();
    $("lane-counts").innerHTML = LANE_ORDER.map((l) => [l, view.tasks.filter((t) => lanes[t.id] === l).length])
      .filter(([, n]) => n).map(([l, n]) => `<span class="tag">${esc(l)} ${n}</span>`).join("");
    const html = `<thead><tr><th>task</th><th>status</th><th>column</th><th>latest gate</th><th>commits</th><th>time</th></tr></thead><tbody>` +
      view.tasks.map((t) => {
        const g = M.latestGate(view, t.id);
        const ts = taskSpan(t.id);
        const commits = (t.commits || []).map((c) => `<span class="tag">${esc(c)}</span>`).join("");
        return `<tr><td><button type="button" class="task-link" data-task="${esc(t.id)}" aria-haspopup="dialog" aria-expanded="false">${esc(t.id)}</button>${t.brief ? `<div class="sub">${esc(t.brief.title)}</div>` : ""}</td>
          <td><span class="chip ${statusChip[t.status] || "plain"}">${esc(t.status)}</span></td>
          <td>${esc(lanes[t.id] || "queued")}</td>
          <td>${g ? verdictChip(g.verdict) : `<span class="sub">none</span>`}</td>
          <td><div class="tags">${commits || `<span class="sub">none</span>`}</div></td>
          <td class="num nowrap">${ts ? esc(M.durationText(ts)) : `<span class="sub">${t.status === "pending" ? "waiting" : "no task span"}</span>`}</td></tr>`;
      }).join("") + `</tbody>`;
    // An unchanged table keeps its rows, so a poll leaves a focused row and the drawer's opener in place.
    if (html === taskTableHtml) return;
    const focused = document.activeElement && document.activeElement.classList.contains("task-link") ? document.activeElement : null;
    $("task-table").innerHTML = html;
    taskTableHtml = html;
    const again = reconnect(focused);
    if (again && again !== document.activeElement) again.focus({ preventScroll: true });
  }
  $("task-table").addEventListener("click", (e) => {
    const b = e.target.closest(".task-link");
    if (b) openTaskPopover(b.dataset.task, b);
  });

  // A task's details, anchored to the board card, graph node or task row that opened it: where it
  // stands, why it failed or stopped, and the way into its drawer.
  function taskFailureHtml(t) {
    const red = view.gates.filter((g) => g.task === t.id && g.failure);
    if (!t.blocked && !red.length) return "";
    const heading = red.length ? "Why it failed" : "Why it stopped";
    const gateOf = (rid) => gateBy[rid] || null;
    const rest = red.length > 1 ? `<p class="sub">+${plural(red.length - 1, "more RED gate run")} in the task drawer</p>` : "";
    return `<div class="pop-fail" role="group" aria-label="${heading}"><h4>${heading}</h4>${t.blocked ? blockHtml(t.blocked, gateOf, false) : ""}${red.length ? gateFailureHtml(red[red.length - 1], false) : ""}${rest}</div>`;
  }
  function openTaskPopover(id, anchor, focus = true) {
    const t = taskBy[id];
    if (!t || !anchor) return false;
    if (anchor === openAnchor && popKind === "task") { closePop(); return true; }
    const g = M.latestGate(view, id);
    const ts = taskSpan(id);
    const tags = (xs) => (xs.length ? `<span class="tags">${xs.map((x) => `<span class="tag">${esc(x)}</span>`).join("")}</span>` : null);
    const deps = t.deps || [], commits = t.commits || [], covers = t.covers || [];
    const rows = (t.brief ? [["goal", t.brief.title]] : []).concat([
      ["status", t.status, `<span class="chip ${statusChip[t.status] || "plain"}">${esc(t.status)}</span>`],
      ["column", laneMap()[id] || "queued"],
      ["worker", [t.model, ts ? M.durationText(ts) : t.status === "pending" ? "waiting" : "no task span"].filter(Boolean).join(" · ")],
      ["deps", "none", tags(deps)],
      ["latest gate", "none", g ? `${verdictChip(g.verdict)} <span class="mono">${esc(g.runId)}</span>` : null],
      ["commits", "none yet", tags(commits)],
      ["covers", "none", tags(covers)]
    ]);
    openPopover(anchor, rows, id, `${taskFailureHtml(t)}<button type="button" class="link-btn pop-open" data-open-task="${esc(id)}">Open task</button>`, focus);
    popKind = "task";
    pinned = true;
    return true;
  }

  // Tabs. Each has an id, which is its #token in the URL, a label, the badges it shows and a panel.
  // The core adds its own here; a module adds one through runViewer.addTab, after the core's.
  const tablist = $("tabs");
  const tabs = new Map();
  let selectedTab = null;
  const hashTab = () => { try { return decodeURIComponent(location.hash.slice(1)); } catch (_) { return ""; } };
  // The tab the reader asked for, by link or click; an unknown or unavailable one shows Overview.
  let wantedTab = hashTab();
  const failedBadges = new Set();

  function paintTab(tab) {
    let list = [];
    if (view && tab.badges) {
      try { list = tab.badges(view) || []; } catch (error) {
        if (!failedBadges.has(tab.id)) {
          failedBadges.add(tab.id);
          pageDamage.push({ source: "tab " + tab.id, reason: "badges: " + String(error && error.message ? error.message : error) });
          renderFooter();
        }
      }
    }
    tab.button.querySelector(".tab-badges").innerHTML = list.map((b) =>
      `<span class="badge ${esc(b.kind)}" data-key="${esc(b.key)}" data-n="${esc(b.n)}" title="${esc(b.title || b.text)}">${esc(b.text)}</span>`).join("");
    tab.button.setAttribute("aria-label", [tab.label].concat(list.map((b) => b.text)).join(", "));
  }

  function showTab(id) {
    closePop(false);
    selectedTab = id;
    tabs.forEach((t) => {
      const on = t.id === id;
      t.panel.hidden = !on;
      t.button.setAttribute("aria-selected", String(on));
      t.button.tabIndex = on ? 0 : -1;
    });
    document.body.dataset.tab = id;
    const tab = tabs.get(id);
    if (tab.shown && view) tab.shown();
  }

  // Hides a tab with nothing to show, and keeps the selection unless it went away.
  function syncTabs() {
    tabs.forEach((t) => { t.button.hidden = !t.available(); });
    const open = (id) => tabs.has(id) && !tabs.get(id).button.hidden;
    const pick = open(wantedTab) ? wantedTab : open("overview") ? "overview" : [...tabs.keys()].find(open);
    if (pick && pick !== selectedTab) showTab(pick);
  }

  function addTab(id, spec) {
    if (tabs.has(id)) throw new Error(`tab ${id} is already added`);
    let panel = document.querySelector(`.tab-panel[data-tab="${CSS.escape(id)}"]`);
    if (!panel) {
      panel = document.createElement("div");
      panel.className = "tab-panel";
      panel.dataset.tab = id;
      panel.hidden = true;
      pop.before(panel);
    }
    panel.id = "tab-" + id;
    panel.setAttribute("role", "tabpanel");
    panel.setAttribute("aria-labelledby", "tab-btn-" + id);
    const button = document.createElement("button");
    button.type = "button";
    button.className = "tab";
    button.id = "tab-btn-" + id;
    button.dataset.tab = id;
    button.tabIndex = -1;
    button.setAttribute("role", "tab");
    button.setAttribute("aria-controls", panel.id);
    button.setAttribute("aria-selected", "false");
    button.innerHTML = `<span>${esc(spec.label)}</span><span class="tab-badges"></span>`;
    tablist.appendChild(button);
    const tab = { id, label: spec.label, badges: spec.badges || null, shown: spec.shown || null, available: spec.available || (() => true), panel, button };
    tabs.set(id, tab);
    paintTab(tab);
    syncTabs();
    return panel;
  }

  function chooseTab(id, focus) {
    wantedTab = id;
    // A plain #token is the 1 part of a link that survives publishing; a sandbox may refuse it.
    try { if (location.hash !== "#" + id) history.replaceState(null, "", "#" + id); } catch (_) {}
    syncTabs();
    if (focus) tabs.get(id).button.focus();
  }
  tablist.addEventListener("click", (e) => { const b = e.target.closest("[role=tab]"); if (b) chooseTab(b.dataset.tab, false); });
  tablist.addEventListener("keydown", (e) => {
    const b = e.target.closest("[role=tab]");
    if (!b) return;
    const ids = [...tabs.values()].filter((t) => !t.button.hidden).map((t) => t.id);
    const i = ids.indexOf(b.dataset.tab);
    const next = { ArrowRight: ids[(i + 1) % ids.length], ArrowLeft: ids[(i - 1 + ids.length) % ids.length], Home: ids[0], End: ids[ids.length - 1] }[e.key];
    if (!next) return;
    e.preventDefault();
    chooseTab(next, true);
  });
  const followHash = () => { wantedTab = hashTab(); syncTabs(); };
  window.addEventListener("hashchange", followHash);
  window.addEventListener("popstate", followHash);

  let coreBadges = {};
  function paintTabs() {
    if (!view) return;
    const stallMin = typeof view.run.stallMin === "number" ? view.run.stallMin : null;
    coreBadges = M.tabBadges(view, { now: liveNowMs(), stallMin });
    tabs.forEach(paintTab);
  }
  [["overview", "Overview"], ["timeline", "Timeline"], ["board", "Board"], ["graph", "Graph"], ["spec", "Spec"], ["gates", "Gates"], ["tokens", "Tokens"]].forEach(([id, label]) => {
    // The board and graph are optional modules: their tab shows once the module draws.
    const mount = document.querySelector(`.tab-panel[data-tab="${id}"] [data-module]`);
    addTab(id, {
      label,
      badges: () => coreBadges[id] || [],
      available: mount ? () => !mount.hidden : undefined,
      // A hidden track measured 0 wide, so it sizes again once it shows.
      shown: id === "timeline" ? sizeTrack : undefined
    });
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
    syncTabs();
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
    $("summary").after(strip);
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
    renderTaskTable();
    renderTimeline();
    renderSpec();
    renderProof();
    renderTokens();
    renderGates();
    renderFooter();
    paintTabs();
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
    const wasPinned = pinned;
    const popTask = popKind === "task" ? { id: openAnchor.dataset.task, anchor: openAnchor } : null;
    closePop(false);
    render();
    modules.forEach((_, name) => runModule(name, "apply"));
    const bar = (id) => (id ? tl.querySelector(`.bar[data-id="${CSS.escape(id)}"]`) : null);
    restoring = true;
    if (barFocus && bar(barFocus)) bar(barFocus).focus({ preventScroll: true });
    restoring = false;
    if (popSpan && bar(popSpan)) {
      openSpan(bar(popSpan), popFocus);
      pinned = wasPinned;
    }
    const taskAnchor = popTask && taskBy[popTask.id] ? reconnect(popTask.anchor) : null;
    if (taskAnchor) openTaskPopover(popTask.id, taskAnchor, popFocus);
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
      $("topbar").appendChild(line);
    }
    line.textContent = message || "";
    line.hidden = !message;
  }
  async function poll() {
    try {
      if (!view) {
        view = await fetchJSON("/view.json");
        render();
        modules.forEach((_, name) => runModule(name, "render"));
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
    addTab,
    openPopover: (anchor, rows, title) => { openPopover(anchor, rows.map(([k, v]) => [k, v]), title); popKind = "other"; },
    openTaskPopover: (id, anchor) => openTaskPopover(id, anchor),
    openTaskDrawer,
    apply
  };

  // The core draws once every module script has run, so Overview can read the board's lanes.
  function start() {
    if (liveMode) {
      document.body.dataset.live = "on";
      $("mode").textContent = "Live";
      renderFooter();
      poll();
    } else if (view) render(); else renderFooter();
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start); else start();
})();
