#!/bin/sh
# req-stored: after confirm-toggle-on.flow.json switches the toggle on, the app's
# standard user defaults hold true under Downloads.confirmLargeDownloads.
set -u
: "${QA_SIM_UDID:?QA_SIM_UDID is required}"
: "${QA_SIM_BUNDLE_ID:?QA_SIM_BUNDLE_ID is required}"
KEY="Downloads.confirmLargeDownloads"

value=$(xcrun simctl spawn "$QA_SIM_UDID" defaults read "$QA_SIM_BUNDLE_ID" "$KEY" 2>&1)
status=$?
if [ -n "${QA_EVIDENCE_DIR:-}" ]; then
  mkdir -p "$QA_EVIDENCE_DIR"
  printf '%s\n' "$value" > "$QA_EVIDENCE_DIR/confirm-toggle-on.defaults.txt"
fi
if [ "$status" -ne 0 ]; then
  echo "FAIL: $KEY not stored in $QA_SIM_BUNDLE_ID defaults: $value" >&2
  exit 1
fi
if [ "$value" != "1" ]; then
  echo "FAIL: $KEY is '$value' in $QA_SIM_BUNDLE_ID defaults, want 1 (true)" >&2
  exit 1
fi
echo "OK: $KEY = true"
