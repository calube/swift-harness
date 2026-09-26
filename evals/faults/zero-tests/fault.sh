#!/usr/bin/env bash
set -euo pipefail
grep -rl '@Test' Packages --include='*.swift' | xargs perl -0pi -e 's/\@Test(\((?:[^()]|\([^()]*\))*\))?//g'; ! grep -rq '@Test' Packages --include='*.swift'
