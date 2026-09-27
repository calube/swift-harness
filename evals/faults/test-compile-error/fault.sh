#!/usr/bin/env bash
set -euo pipefail
t=Packages/CounterFeature/Tests/CounterCoreTests/CounterFeatureTests.swift
perl -0pi -e 's/(\n\}\s*)\z/\n\n  \@Test("does not compile on purpose")\n  func doesNotCompile() { let n: Int = "not an int"; #expect(n == 0) }\n}\n/' "$t"
grep -q doesNotCompile "$t"
