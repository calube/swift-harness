# `probe` self-test seeds

Each case's `probes/*.snippet.swift` is the same file `probe-builds-scratch-package` recorded at
`gate/Fixtures/probe/host-snippets/`, reused rather than re-authored. The self-test runner builds
each one against the shared host-only scratch package at `gate/Fixtures/probe/HostTarget`, in a
temp root, never against this checkout.
