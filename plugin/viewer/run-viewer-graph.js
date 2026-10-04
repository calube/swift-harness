// The plan graph module: the tasks as a dependency graph in waves left to right, 1 node per task
// coloured by its board lane and 1 edge per dep. Loaded after the core page as a classic script;
// it publishes `RunViewGraph` and registers with the page when the page is there.
(function (root) {
  function layers() {
    return { waves: [], cycle: null };
  }

  root.RunViewGraph = { layers };
})(globalThis);
