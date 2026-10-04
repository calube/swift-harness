// The board module: 1 card per task in queued, building, gating, review, merged, or the blocked
// lane. Loaded after the core page as a classic script; it publishes `RunViewBoard` and registers
// with the page when the page is there.
(function (root) {
  const LANES = ["queued", "building", "gating", "review", "merged", "blocked"];

  function columns() {
    return Object.fromEntries(LANES.map((lane) => [lane, []]));
  }

  root.RunViewBoard = { LANES, columns };
})(globalThis);
