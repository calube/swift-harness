# `evidence check` self-test seeds

`valid/` and `tampered-capture/` share one real capture, `captures/7f66639af7446921f447ce6e225cec40651d40d287bf8cb781f80360162639fb.txt`.
It was produced by running the command itself, never hand-written:

```
swiftgate evidence capture --design docs/example/designs/seed.md -- echo sentinel-output-value
```

`tampered-capture/`'s copy of that file has byte 10 XORed with `0x01` (a single flipped bit inside
the first line); its claim keeps the original file's pin, so the stored hash no longer matches.
