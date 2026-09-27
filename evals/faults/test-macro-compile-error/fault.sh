#!/usr/bin/env bash
set -euo pipefail
t=Packages/CounterFeature/Tests/CounterCoreTests/CounterFeatureTests.swift
perl -0pi -e 's/(\n\}\s*)\z/\n\n  func throwsInt() throws -> Int { 1 }\n\n  \@Test("try inside expect in a non-throwing test")\n  func tryInsideExpect() { #expect(try throwsInt() == 1) }\n}\n/' "$t"
grep -q tryInsideExpect "$t"
