// The Validation tab: a strip counting pass, red, unverified and waiting rows, the rows grouped
// by the task each runs after, then the kept XCUITest flows by flow and test. A red row opens "Why
// it failed"; an unverified row, or a flow missing its video or sheet, "Why unverified". A flow
// lists its steps, each linked to the video at its offset, and links its contact sheet. Evidence
// is linked or named by path, never embedded. Loaded after the core page as a classic script; it
// adds its tab, gives the task popover each task's rows, and registers with the page.
(function (root) {
  const M = root.RunViewModel;
  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  const RESULT = { pass: "ok", red: "bad", unverified: "warn", waiting: "plain" };
  let current = null;
  let mount = null;
  // The rows on screen, by their group and row number, for the popover a button opens; the rows
  // of the open task popover are kept apart, since a re-render of the tab mustn't drop them.
  let shown = {};
  let inTask = {};

  const panel = runViewer.addTab("validation", {
    label: "Validation",
    badges: (view) => M.validationBadges(view),
    available: () => !!(current && current.validation && (current.validation.rows.length || (current.validation.keptFlows || []).length))
  });
  mount = document.createElement("section");
  mount.className = "panel";
  mount.setAttribute("aria-label", "Validation");
  mount.dataset.module = "validation";
  mount.hidden = true;
  panel.appendChild(mount);

  const chip = (result) => `<span class="chip ${RESULT[result] || "plain"}">${esc(result)}</span>`;
  const what = (row) => `${row.layer} check ${row.check != null ? row.check : "of row " + row.row}`;

  const gaps = (flow) => (flow ? [flow.videoUnverified, flow.sheetUnverified].some((g) => g != null) : false);
  const whyOf = (row) => (row.result === "red" ? "Why it failed" : row.result === "unverified" || gaps(row.flow) ? "Why unverified" : null);
  const whyButton = (why, key) => `<button type="button" class="link-btn qa-why" data-key="${esc(key)}" aria-haspopup="dialog" aria-expanded="false">${why}</button>`;
  const seconds = (ms) => (Math.max(0, ms) / 1000).toFixed(1) + " s";

  // A flow's steps with their marks, each linked to the video at its offset when there is a
  // video, then its contact sheet's link.
  function flowHtml(flow) {
    const steps = flow.steps.map((st) => {
      const label = `step ${st.n}${st.label != null ? " " + st.label : ""}`;
      const text = flow.video != null
        ? `<a class="qa-step-link" href="${esc(M.evidenceHref(flow.run, flow.video, st.offsetMs))}" target="_blank" rel="noopener">${esc(label)}</a>`
        : `<span>${esc(label)}</span>`;
      return `<li class="qa-step" data-n="${st.n}" data-ok="${st.ok}"><span class="qa-mark ${st.ok ? "ok" : "bad"}" role="img" aria-label="${st.ok ? "passed" : "failed"}">${st.ok ? "✓" : "✗"}</span>${text}<span class="sub num">${seconds(st.offsetMs)}</span></li>`;
    }).join("");
    const links = [
      flow.video != null ? `<a class="qa-video" href="${esc(M.evidenceHref(flow.run, flow.video))}" target="_blank" rel="noopener">video</a>` : `<span class="sub">no video</span>`,
      flow.sheet != null ? `<a class="qa-sheet" href="${esc(M.evidenceHref(flow.run, flow.sheet))}" target="_blank" rel="noopener">contact sheet</a>` : `<span class="sub">no contact sheet</span>`
    ].join(" · ");
    return `<div class="qa-flow"><ol class="qa-steps" aria-label="Flow steps">${steps}</ol><div class="qa-links">${links}</div></div>`;
  }

  function rowHtml(row, key) {
    const why = whyOf(row);
    return `<li class="qa-row" data-row="${row.row}" data-result="${esc(row.result)}">${chip(row.result)}
      <span class="mono">row ${row.row}</span><span class="qa-layer">${esc(row.layer)}</span>
      <span class="qa-req mono">${esc(row.requirement)}</span>
      ${row.check != null ? `<code class="qa-check">${esc(row.check)}</code>` : ""}
      <span class="sub num">${row.result === "waiting" ? "" : esc(M.fmtMs(row.ms))}</span>${why ? whyButton(why, key) : ""}${row.flow ? flowHtml(row.flow) : ""}</li>`;
  }

  function keptHtml(k, key) {
    const test = k.test != null ? k.test : "a test the guard dropped";
    const where = [`gate run <span class="mono">${esc(k.gateRun)}</span>`].concat(k.task != null ? [`task <span class="mono">${esc(k.task)}</span>`] : []).join(" · ");
    const ok = k.flow.steps.every((st) => st.ok);
    return `<li class="qa-kept-flow" data-test="${esc(test)}">${chip(ok ? "pass" : "red")}
      <code class="qa-check">${esc(test)}</code><span class="sub">${where}</span>${gaps(k.flow) ? whyButton("Why unverified", key) : ""}${flowHtml(k.flow)}</li>`;
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
    const kept = M.keptFlowGroups(view).map((g, gi) => {
      const title = g.name == null ? "no flow named" : g.name;
      const flows = g.flows.map((k, fi) => { const key = "k:" + gi + ":" + fi; shown[key] = { kept: k }; return keptHtml(k, key); });
      return `<div class="qa-kept-group" data-flow="${esc(g.name == null ? "" : g.name)}"><h4 class="mono">${esc(title)}</h4><ul class="qa-rows">${flows.join("")}</ul></div>`;
    }).join("");
    const keptSection = kept ? `<section class="qa-group qa-kept" aria-label="Kept flows"><h3>Kept flows</h3>${kept}</section>` : "";
    mount.innerHTML = `<div class="head" style="justify-content:space-between"><h2>Validation</h2><span class="sub">plan <span class="mono">${esc(v.plan)}</span></span></div>
      <div class="stats qa-strip" aria-label="Validation counts">${strip}</div>${groups}${keptSection}`;
  }

  // The rows a task's popover lists: each row that runs after it, with its Why button.
  function taskHtml(view, id) {
    const v = view.validation;
    if (!v) return "";
    const rows = v.rows.filter((row) => row.runsAfter.includes(id));
    inTask = {};
    if (!rows.length) return "";
    const items = rows.map((row) => {
      const key = "t:" + id + ":" + row.row;
      inTask[key] = row;
      const why = whyOf(row);
      return `<li class="qa-row" data-row="${row.row}" data-result="${esc(row.result)}">${chip(row.result)}<span class="mono">row ${row.row}</span><span class="qa-layer">${esc(row.layer)}</span>${row.check != null ? `<code class="qa-check">${esc(row.check)}</code>` : ""}${why ? whyButton(why, key) : ""}</li>`;
    }).join("");
    return `<div class="pop-validation" role="group" aria-label="Validation rows"><h4>Validation rows</h4><ul class="qa-rows">${items}</ul></div>`;
  }

  const gapRows = (flow) => (flow ? [["video", flow.videoUnverified], ["contact sheet", flow.sheetUnverified]].filter(([, g]) => g != null).map(([k, g]) => [k, M.gapText(g)]) : []);
  const missing = (flow) => [flow.videoUnverified != null ? "the flow's video" : null, flow.sheetUnverified != null ? "the video's contact sheet" : null].filter(Boolean).join(" and ");

  // `anchor` is the button itself, or what the task popover was anchored to when the button sits
  // inside that popover, which this popover replaces.
  function open(button, anchor) {
    const entry = shown[button.dataset.key] || inTask[button.dataset.key];
    if (!entry) return;
    if (entry.kept) {
      const k = entry.kept;
      runViewer.openPopover(anchor, [
        ["test", k.test != null ? k.test : "not shown"],
        ["didn't run", missing(k.flow)],
        ...gapRows(k.flow),
        ["gate run", k.gateRun]
      ], "Why unverified");
      return;
    }
    const row = entry;
    const evidence = row.evidence.length ? row.evidence.join(", ") : "none saved";
    if (row.result === "red") {
      const output = row.output.length
        ? `<div class="qa-output" role="group" aria-label="Saved output"><h4>Saved output${row.outputCut ? `, last ${row.output.length} lines` : ""}</h4><pre>${esc(row.output.join("\n"))}</pre></div>`
        : `<p class="sub">no saved output</p>`;
      const failed = row.flow ? row.flow.steps.find((st) => !st.ok) : null;
      runViewer.openPopover(anchor, [
        ["requirement", row.requirement],
        ["layer", row.layer],
        ["check", row.check != null ? row.check : "not in the report"],
        ...(failed ? [["failing step", `step ${failed.n}${failed.label != null ? " " + failed.label : ""}`]] : []),
        ["exit status", row.exitStatus != null ? String(row.exitStatus) : "it never exited"],
        ["why", row.message != null ? row.message : "the report holds no reason"],
        ...gapRows(row.flow),
        ["evidence", evidence],
        ["qa run", row.qaRun]
      ], "Why it failed", output);
    } else if (row.result === "unverified") {
      runViewer.openPopover(anchor, [
        ["requirement", row.requirement],
        ["didn't run", what(row)],
        ["why", row.message != null ? row.message : "the report holds no reason"],
        ...gapRows(row.flow),
        ["qa run", row.qaRun]
      ], "Why unverified");
    } else {
      runViewer.openPopover(anchor, [
        ["requirement", row.requirement],
        ["didn't run", missing(row.flow)],
        ...gapRows(row.flow),
        ["result", `${row.result}: the row passes or fails on its steps alone`],
        ["qa run", row.qaRun]
      ], "Why unverified");
    }
  }
  mount.addEventListener("click", (e) => { const b = e.target.closest(".qa-why"); if (b) open(b, b); });
  document.getElementById("pop").addEventListener("click", (e) => {
    const b = e.target.closest(".qa-why");
    if (b) open(b, runViewer.popoverAnchor() || b);
  });

  runViewer.register("validation", { render: (view) => render(view), apply: (view) => render(view), taskHtml });
})(globalThis);
