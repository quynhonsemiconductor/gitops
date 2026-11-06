#!/usr/bin/env bash
# ── self-test for scripts/check-coder-template-names.sh ────────────────────
#
# The fixture is the template BEFORE the 2026-11-07 fix: object names built from
# the mixed-case Entra username that made the first workspace build fail. The
# checker must reject it, and accept the repository's current template.
set -euo pipefail
cd "$(dirname "$0")/.."

expect() { # file, expected-exit, why
  ./scripts/check-coder-template-names.sh "$1" >/dev/null 2>&1 && got=0 || got=1
  if [ "$got" != "$2" ]; then
    echo "FAIL: $3: checker exited $got, expected $2"
    exit 1
  fi
  echo "ok: $3"
}

expect scripts/fixtures/coder-template-names/mixed-case-owner.tf 1 "the pre-fix template (mixed-case names) is caught"
expect platform/coder/templates/vlsi-workspace/main.tf 0 "the repository template passes"
