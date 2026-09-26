#!/usr/bin/env bash
set -euo pipefail
sed -i '' 's/^xcode = .*/xcode = "25.0"/' .swiftgate.toml
