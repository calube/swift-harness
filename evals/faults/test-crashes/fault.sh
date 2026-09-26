#!/usr/bin/env bash
set -euo pipefail
perl -0pi -e 's/(\n\}\s*)\z/\n\n  \@Test("crashes on purpose")\n  func crashesOnPurpose() { let xs: [Int] = []; _ = xs[1] }\n}\n/' Packages/CounterFeature/Tests/CounterCoreTests/CounterFeatureTests.swift; grep -q crashesOnPurpose Packages/CounterFeature/Tests/CounterCoreTests/CounterFeatureTests.swift
