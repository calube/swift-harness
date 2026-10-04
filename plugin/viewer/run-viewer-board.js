// The board module: 1 card per task in queued, building, gating, review, merged, or the blocked
// lane. Loaded after the core page as a classic script; it publishes `RunViewBoard` and registers
// with the page when the page is there.
(function (root) {
  const LANES = ["queued", "building", "gating", "review", "merged", "blocked"];
  const BLOCKED = new Set(["blocked", "needs-replan", "abandoned"]);
  // An open merge span is still waiting on its merge gate, so it reads as review, not merged.
  const STAGE = { worker: "building", fix: "building", verify: "gating", gate: "gating", review: "review", merge: "review" };
  const ms = (iso) => (iso == null ? null : Date.parse(iso));

  function laneFor(task, own, halted) {
    if (halted || BLOCKED.has(task.status)) return "blocked";
    if (task.status === "done") return "merged";
    const open = own.filter((s) => s.end == null && STAGE[s.phase]).sort((a, b) => ms(b.start) - ms(a.start));
    if (open.length) return STAGE[open[0].phase];
    return task.status === "in-progress" ? "building" : "queued";
  }

  // The verdict of the task's latest finished gate span, else of its last gate record.
  function lastGate(task, own, gateBy, gates) {
    const ran = own.filter((s) => s.phase === "gate" && s.gateRun && s.end != null).sort((a, b) => ms(a.start) - ms(b.start));
    const last = ran[ran.length - 1];
    if (last) return gateBy[last.gateRun] ? gateBy[last.gateRun].verdict : last.outcome === "red" ? "RED" : "GREEN";
    const records = gates.filter((g) => g.task === task.id);
    return records.length ? records[records.length - 1].verdict : null;
  }

  function elapsed(task, own, cut) {
    const fmtMin = root.RunViewModel.fmtMin;
    if (!own.length) return "waiting";
    const taskSpan = own.find((s) => s.phase === "task");
    const start = taskSpan ? ms(taskSpan.start) : Math.min(...own.map((s) => ms(s.start)));
    let end = taskSpan && taskSpan.end != null ? ms(taskSpan.end) : ms(task.mergedAt);
    if (end == null) end = own.every((s) => s.end != null) && !taskSpan ? Math.max(...own.map((s) => ms(s.end))) : cut;
    return fmtMin(Math.max(0, end - start) / 60000);
  }

  // Each lane's cards in the view's task order. `now` cuts open spans; it defaults to the run's last
  // event, as the timeline does.
  function columns(view, now) {
    const cut = now != null ? now : root.RunViewModel.lastEventMs(view);
    const spans = view.spans || [];
    const gates = view.gates || [];
    const gateBy = Object.fromEntries(gates.map((g) => [g.runId, g]));
    const halted = new Set((view.halts || []).filter((h) => h.task != null && h.answer == null && h.waitMs == null).map((h) => h.task));
    const out = Object.fromEntries(LANES.map((lane) => [lane, []]));
    (view.tasks || []).forEach((task) => {
      const own = spans.filter((s) => s.task === task.id);
      const lane = laneFor(task, own, halted.has(task.id));
      out[lane].push({
        id: task.id, lane, model: task.model, elapsed: elapsed(task, own, cut),
        lastGate: lastGate(task, own, gateBy, gates), covers: task.covers || []
      });
    });
    return out;
  }

  root.RunViewBoard = { LANES, columns };

  const runViewer = root.runViewer;
  if (!runViewer || typeof document === "undefined") return;

  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  const verdictChip = (v) => `<span class="chip ${v === "GREEN" ? "ok" : v === "RED" ? "bad" : "warn"}">${esc(v)}</span>`;
  const laneColour = { queued: "--muted", building: "--bar-worker", gating: "--warn", review: "--bar-review", merged: "--ok", blocked: "--bad" };

  let board = null, note = null;
  const lanes = {};
  // Cards persist by task id, so a card that moves keeps its focus and stays the drawer's opener.
  const cards = new Map();

  function build(mount) {
    mount.innerHTML = `<div class="head" style="justify-content:space-between"><h2>Board</h2></div>
      <p class="sub board-note"></p>
      <div class="board-scroll" tabindex="0" aria-label="Task board, scrolls horizontally"><div class="board"></div></div>`;
    note = mount.querySelector(".board-note");
    board = mount.querySelector(".board");
    LANES.forEach((lane) => {
      const el = document.createElement("div");
      el.className = "lane" + (lane === "blocked" ? " blocked" : "");
      el.setAttribute("role", "group");
      el.dataset.lane = lane;
      board.appendChild(el);
      lanes[lane] = el;
    });
    cards.clear();
    board.addEventListener("click", (e) => {
      const c = e.target.closest(".card");
      if (c) runViewer.openTaskPopover(c.dataset.task, c);
    });
  }

  function cardFor(c) {
    let el = cards.get(c.id);
    if (!el) {
      el = document.createElement("button");
      el.type = "button";
      el.className = "card";
      el.dataset.task = c.id;
      el.setAttribute("aria-haspopup", "dialog");
      el.setAttribute("aria-expanded", "false");
      cards.set(c.id, el);
    }
    el.style.setProperty("--c", `var(${laneColour[c.lane]})`);
    el.setAttribute("aria-label", [c.id, c.lane, c.model, c.elapsed, `last gate ${c.lastGate || "none"}`].filter(Boolean).join(", "));
    el.innerHTML = `<span class="card-top"><span class="card-id">${esc(c.id)}</span>${c.model ? `<span class="chip plain">${esc(c.model)}</span>` : ""}</span>
      <span class="card-meta"><span class="num">${esc(c.elapsed)}</span>${c.lastGate ? verdictChip(c.lastGate) : `<span class="chip plain">no gate yet</span>`}</span>
      <span class="tags">${c.covers.length ? c.covers.map((t) => `<span class="tag">${esc(t)}</span>`).join("") : `<span class="sub card-none">no spec id</span>`}</span>`;
    return el;
  }

  function update(view) {
    const cut = root.RunViewModel.lastEventMs(view);
    const byLane = columns(view, cut);
    const focused = document.activeElement;
    const seen = new Set();
    LANES.forEach((lane) => {
      const inLane = byLane[lane];
      const head = document.createElement("div");
      head.className = "lane-head";
      head.innerHTML = `<span>${lane}</span><span class="num">${inLane.length}</span>`;
      const body = inLane.length ? inLane.map((c) => { seen.add(c.id); return cardFor(c); }) : [Object.assign(document.createElement("div"), { className: "lane-empty", textContent: lane === "blocked" ? "no halts" : "empty" })];
      lanes[lane].setAttribute("aria-label", `${lane}, ${inLane.length} tasks`);
      lanes[lane].replaceChildren(head, ...body);
    });
    [...cards.keys()].forEach((id) => { if (!seen.has(id)) cards.delete(id); });
    if (focused && focused.classList.contains("card") && focused.isConnected && document.activeElement !== focused) focused.focus({ preventScroll: true });
    const fmtMin = root.RunViewModel.fmtMin;
    const at = fmtMin(Math.max(0, cut - ms(view.run.startedAt)) / 60000);
    const total = (view.tasks || []).length;
    note.textContent = view.run.state === "running"
      ? `Live at +${at}: ${total - byLane.merged.length} tasks in flight.`
      : `Final state at +${at}: ${byLane.merged.length} of ${total} merged, ${byLane.blocked.length} blocked.`;
  }

  runViewer.register("board", {
    render(view, mount) {
      if (!board || !mount.contains(board)) build(mount);
      update(view);
    },
    apply: update
  });
})(globalThis);
