# `sim-verify` self-test seeds

Each case's `sim/` folder is a real run's `sim/` folder from `sim up` and `sim snap`; the capture is
in `Tests/Fixtures/README.md` under `AgentDevice/seeded`. Self-test loads the folder in place and
applies the `sim verify` evidence rules without a checkout HEAD, so `sim.stale-head` isn't judged.
`unlabeled-controls` holds a button with no identifier and an icon-only button with no label;
`valid` is the committed sample app's screen.
