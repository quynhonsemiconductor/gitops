#!/usr/bin/env bash
# ── flags the push script passes must exist in the pinned coder CLI ────────
#
# scripts/coder-push-template.sh is owner-run, intermittently, against a
# digest-pinned image. A flag that the image does not have fails on the owner's
# laptop at 01:00, not in review — #399 (`--directory` parsed as a `coder
# server` flag because the image ENTRYPOINT is ["/opt/coder","server"]) and the
# `--max-ttl` that no longer exists in 2.38.1 are both that class.
#
# The image comes from the script itself (single source). Run this in CI.
set -euo pipefail
cd "$(dirname "$0")/.."

SCRIPT=${1:-scripts/coder-push-template.sh}
IMAGE=$(sed -nE 's/^IMAGE="([^"]+)".*/\1/p' "$SCRIPT" | head -1)
[ -n "$IMAGE" ] || { echo "::error file=$SCRIPT::no IMAGE= pin found"; exit 1; }

fail=0
help() { docker run --rm --entrypoint /opt/coder "$IMAGE" "$@" --help 2>&1; }

# The entrypoint override is what keeps the CLI from becoming `coder server
# coder ...`; without it every call dies on an unknown root flag.
overrides=$(grep -c -- '--entrypoint /opt/coder' "$SCRIPT" || true)
if [ "$overrides" -lt 2 ]; then
  echo "::error file=$SCRIPT::expected --entrypoint /opt/coder on both docker runs, found $overrides"
  fail=1
fi
if grep -vE '^[[:space:]]*#' "$SCRIPT" | grep -qE '^[[:space:]]*coder templates'; then
  echo "::error file=$SCRIPT::a docker run still passes the leading 'coder' word (the ENTRYPOINT already runs 'coder server')"
  fail=1
fi

push=$(help templates push)
for f in --directory --yes --activate; do
  if printf '%s\n' "$push" | grep -q -- "$f"; then
    echo "ok: templates push $f"
  else
    echo "::error file=$SCRIPT::templates push has no $f in $IMAGE"
    fail=1
  fi
done

edit=$(help templates edit)
if printf '%s\n' "$edit" | grep -q -- '--default-ttl'; then
  echo "ok: templates edit --default-ttl"
else
  echo "::error file=$SCRIPT::templates edit has no --default-ttl in $IMAGE"
  fail=1
fi

# `--max-ttl` is Premium-only/absent in OSS 2.38.1; the script must not pass it.
if grep -vE '^[[:space:]]*#' "$SCRIPT" | grep -q -- '--max-ttl'; then
  echo "::error file=$SCRIPT::passes --max-ttl, which templates edit --help does not list"
  fail=1
fi

exit "$fail"
