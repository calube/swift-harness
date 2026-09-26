# `evidence check` self-test seeds

`valid/` and `tampered-capture/` share one real capture, `captures/7f66639af7446921f447ce6e225cec40651d40d287bf8cb781f80360162639fb.txt`.
It was produced by running the command itself, never hand-written:

```
swiftgate evidence capture --design docs/example/designs/seed.md -- echo sentinel-output-value
```

`tampered-capture/`'s copy of that file has byte 10 XORed with `0x01` (a single flipped bit inside
the first line); its claim keeps the original file's pin, so the stored hash no longer matches.

The three probe seeds start from one real probe run, never a hand-written verdict. From an empty
directory holding only `docs/example/designs/seed.evidence/probes/ev-string-has-prefix-exists.snippet.swift`
(a copy of `gate/Fixtures/probe/host-snippets/`'s file):

```
swiftgate probe --design docs/example/designs/seed.md --package <gate>/Fixtures/probe/HostTarget \
  --target HostTarget --cache-home <scratch>/home
```

That writes the wrapper `Probe_ev_string_has_prefix_exists.swift` and its verdict, which records
the sha256 of the snippet and of the wrapper. Each seed then tampers with one thing:

- `tampered-probe/`: the snippet is replaced after the run, so its hash no longer matches.
- `probe-without-source/`: only the verdict is kept; the snippet and wrapper are gone.
- `hand-written-probe/`: the verdict's hashes are removed with
  `jq 'del(.snippetSha256, .sourceSha256)'`, the shape of a verdict no probe wrote.

`escaping-loc/`, `respelled-checkout/` and `duplicate-claim-id/` are claims only: a checkout
reached through `..`, a checkout spelled `.BUILD/Checkouts` whose pin disagrees with
`Package.resolved`, and two claims sharing one id.
