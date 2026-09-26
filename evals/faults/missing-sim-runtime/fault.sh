#!/usr/bin/env bash
set -euo pipefail
sed -i '' 's/^os = .*/os = "19.0"/' .swiftgate.toml
