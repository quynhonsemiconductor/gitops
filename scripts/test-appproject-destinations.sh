#!/usr/bin/env bash
# ── self-test for scripts/check-appproject-destinations.sh ─────────────────
#
# The failure this guards against reached main twice (#385, #388): a namespace
# added to platform/ that no project destination admits. The fixtures prove the
# checker fails on the missing destination and on a run that inspects nothing.
set -euo pipefail
cd "$(dirname "$0")/.."

check() { ./scripts/check-appproject-destinations.sh "scripts/fixtures/appproject-destinations/$1" >/dev/null 2>&1 && echo 0 || echo 1; }

expect() { # fixture, expected-exit, why
  got=$(check "$1")
  if [ "$got" != "$2" ]; then
    echo "FAIL: fixture $1: checker exited $got, expected $2 ($3)"
    exit 1
  fi
  echo "ok: $1 -> exit $2 ($3)"
}

expect ok       0 "data-prod is a destination"
expect missing  1 "gpu-monitoring is missing from the destinations"
expect nothing  1 "a root with no namespaced manifest is not a pass"

./scripts/check-appproject-destinations.sh >/dev/null && echo "ok: repository" || { echo "FAIL: repository"; exit 1; }
