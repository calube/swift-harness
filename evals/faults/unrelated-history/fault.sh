#!/usr/bin/env bash
set -euo pipefail
git checkout -q --orphan other && git -c user.name=e -c user.email=e@e commit -qm other --allow-empty && git push -q -f origin other:main && git checkout -q main && git fetch -q origin
