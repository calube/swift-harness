#!/usr/bin/env bash
set -euo pipefail
sed -i '' 's/^xcode = .*/xcode = "26"/' .swiftgate.toml
grep -q '^xcode = "26"$' .swiftgate.toml
