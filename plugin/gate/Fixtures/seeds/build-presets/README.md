# Build preset self-test seeds

Each case's `config.toml` is a hand-authored `.swiftgate.toml`, decoded as `swiftgate` decodes the
real one. Every schema issue is named `config.<kind>(<path>)`, so the answer key says which key
is wrong.

`missing-key` has a `[build.presets.broken]` table without `merge_gate`. `valid` has every key.
