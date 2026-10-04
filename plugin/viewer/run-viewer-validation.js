// The Validation tab: a strip counting pass, red, unverified and waiting rows, then the rows
// grouped by the task each runs after. A red row opens "Why it failed", an unverified row "Why
// unverified". Evidence is named by path, never embedded. Loaded after the core page as a classic
// script; it adds its tab and registers with the page.
(function (root) {
  const M = root.RunViewModel;
  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  const RESULT = { pass: "ok", red: "bad", unverified: "warn", waiting: "plain" };
  let current = null;
  let mount = null;
  // The rows on screen, by their group and row number, for the popover a button opens.
  let shown = {};

  const panel = runViewer.addTab("validation", {
    label: "Validation",
    badges: (view) => M.validationBadges(view),
    available: () => !!(current && current.validation && current.validation.rows.length)
  });
  mount = document.createElement("section");
  mount.className = "panel";
  mount.setAttribute("aria-label", "Validation");
  mount.dataset.module = "validation";
  mount.hidden = true;
  panel.appendChild(mount);

  const chip = (result) => `<span class="chip ${RESULT[result] || "plain"}">${esc(result)}</span>`;
  const what = (row) => `${row.layer} check ${row.check != null ? row.check : "of row " + row.row}`;

  function rowHtml(row, key) {
    const why = row.result === "red" ? "Why it failed" : row.result === "unverified" ? "Why unverified" : null;
    const button = why ? `<button type="button" class="link-btn qa-why" data-key="${esc(key)}" aria-haspopup="dialog" aria-expanded="false">${why}</button>` : "";
    return `<li class="qa-row" data-row="${row.row}" data-result="${esc(row.result)}">${chip(row.result)}
      <span class="mono">row ${row.row}</span><span class="qa-layer">${esc(row.layer)}</span>
      <span class="qa-req mono">${esc(row.requirement)}</span>
      ${row.check != null ? `<code class="qa-check">${esc(row.check)}</code>` : ""}
      <span class="sub num">${row.result === "waiting" ? "" : esc(M.fmtMs(row.ms))}</span>${button}</li>`;
  }

  function waitingHtml(row) {
    return `<li class="qa-row qa-waiting" data-row="${row.row}" data-result="waiting">${chip("waiting")}
      <span>waiting on ${row.waitingOn.map((t) => `<span class="mono">${esc(t)}</span>`).join(", ")}</span>
      <span class="sub">row ${row.row} · ${esc(row.layer)} · <span class="mono">${esc(row.requirement)}</span></span></li>`;
  }

  function render(view) {
    current = view;
    shown = {};
    const v = view.validation;
    if (!v) { mount.innerHTML = ""; return; }
    const c = v.counts;
    const strip = [["pass", c.pass], ["red", c.red], ["unverified", c.unverified], ["waiting", c.waiting]]
      .map(([k, n]) => `<div class="stat qa-count" data-result="${k}"><b class="num">${n}</b><span>${k}</span></div>`).join("");
    const groups = M.validationGroups(view).map((g, gi) => {
      const rows = g.rows.map((row) => { const key = gi + ":" + row.row; shown[key] = row; return rowHtml(row, key); });
      const title = g.task == null ? "no task named" : g.task;
      const task = g.task != null ? (view.tasks || []).find((t) => t.id === g.task) : null;
      return `<section class="qa-group" data-task="${esc(g.task == null ? "" : g.task)}" aria-label="${esc(title)}">
        <h3><span class="mono">${esc(title)}</span>${task ? ` <span class="chip plain">${esc(task.status)}</span>` : ""}</h3>
        <ul class="qa-rows">${rows.join("")}${g.waiting.map(waitingHtml).join("")}</ul></section>`;
    }).join("");
    mount.innerHTML = `<div class="head" style="justify-content:space-between"><h2>Validation</h2><span class="sub">plan <span class="mono">${esc(v.plan)}</span></span></div>
      <div class="stats qa-strip" aria-label="Validation counts">${strip}</div>${groups}`;
  }

  function open(button) {
    const row = shown[button.dataset.key];
    if (!row) return;
    const evidence = row.evidence.length ? row.evidence.join(", ") : "none saved";
    if (row.result === "red") {
      const output = row.output.length
        ? `<div class="qa-output" role="group" aria-label="Saved output"><h4>Saved output${row.outputCut ? `, last ${row.output.length} lines` : ""}</h4><pre>${esc(row.output.join("\n"))}</pre></div>`
        : `<p class="sub">no saved output</p>`;
      runViewer.openPopover(button, [
        ["requirement", row.requirement],
        ["layer", row.layer],
        ["check", row.check != null ? row.check : "not in the report"],
        ["exit status", row.exitStatus != null ? String(row.exitStatus) : "it never exited"],
        ["why", row.message != null ? row.message : "the report holds no reason"],
        ["evidence", evidence],
        ["qa run", row.qaRun]
      ], "Why it failed", output);
    } else {
      runViewer.openPopover(button, [
        ["requirement", row.requirement],
        ["didn't run", what(row)],
        ["why", row.message != null ? row.message : "the report holds no reason"],
        ["qa run", row.qaRun]
      ], "Why unverified");
    }
  }
  mount.addEventListener("click", (e) => { const b = e.target.closest(".qa-why"); if (b) open(b); });

  runViewer.register("validation", { render: (view) => render(view), apply: (view) => render(view) });
})(globalThis);
