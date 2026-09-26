#!/usr/bin/env bash
set -euo pipefail
m=Packages/CounterFeature/Package.swift
perl -pi -e 's/exact: "1\.26\.2"/exact: "99.0.0"/' "$m"
grep -q 'exact: "99.0.0"' "$m"
