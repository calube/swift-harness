// Pure functions over a RunView: merging partials, laying out the timeline, and formatting.
// Loaded as a classic script so the report can inline it; it publishes one global.
(function (root) {
  const RunViewModel = {
    apply: (view) => view,
    normalize: () => ({ spans: [], wall: 0 }),
    lanes: () => [],
    scale: (zoom, width) => width,
    labelFits: () => true,
    blocks: () => [],
    activity: () => [],
    waveOf: () => 1,
    toolSummary: () => null,
    durationText: () => "",
    fmtTok: (n) => String(n),
    fmtTokens: (t) => String(t),
    fmtMin: (m) => String(m),
    fmtMs: (ms) => String(ms),
    shortRun: (id) => id
  };
  root.RunViewModel = RunViewModel;
})(globalThis);
