#!/usr/bin/env bash
# ── self-test for scripts/check-barman-retention.sh ────────────────────────
#
# A static check nobody has watched fail is a check that can silently inspect
# nothing (this one did, during development: the destination path was matched
# at the wrong indentation and every real ObjectStore was skipped). Each fixture
# below is a miniature repo root; the expectations are the checker's exit code.
set -euo pipefail
cd "$(dirname "$0")/.."

check() { ./scripts/check-barman-retention.sh "scripts/fixtures/barman-retention/$1" >/dev/null 2>&1 && echo 0 || echo 1; }

expect() { # fixture, expected-exit, why
  got=$(check "$1")
  if [ "$got" != "$2" ]; then
    echo "FAIL: fixture $1: checker exited $got, expected $2 ($3)"
    exit 1
  fi
  echo "ok: $1 -> exit $2 ($3)"
}

expect ok                     0 "14d is below the 30-day lifecycle"
expect keep-restore-test       0 "the restore-test mirror without a policy is skipped, the prod ObjectStore is checked"
expect bad-at-lifecycle        1 "retention at the lifecycle age is rejected"
expect missing-policy          1 "a prod ObjectStore with no retentionPolicy is rejected"

# And the real repository must pass.
./scripts/check-barman-retention.sh >/dev/null && echo "ok: repository" || { echo "FAIL: repository"; exit 1; }
