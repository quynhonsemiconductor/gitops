#!/usr/bin/env bash
# ── self-test for scripts/check-coder-cli-flags.sh ─────────────────────────
#
# A checker that cannot fail is decoration. The fixtures are copies of the real
# script with one historical bug re-introduced each; the pinned image is only
# pulled once (the real-script run at the end).
set -euo pipefail
cd "$(dirname "$0")/.."

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
src=scripts/coder-push-template.sh

expect() { # file, expected-exit, why
  ./scripts/check-coder-cli-flags.sh "$1" >/dev/null 2>&1 && got=0 || got=1
  if [ "$got" != "$2" ]; then
    echo "FAIL: $3: checker exited $got, expected $2"
    exit 1
  fi
  echo "ok: $3"
}

# 1. #399's bug: no entrypoint override (the CLI becomes `coder server coder …`).
sed 's#--entrypoint /opt/coder##g' "$src" > "$tmp/no-entrypoint.sh"
expect "$tmp/no-entrypoint.sh" 1 "missing --entrypoint is caught"

# 2. The removed --max-ttl.
cp "$src" "$tmp/max-ttl.sh"
printf '\ndocker run --rm --entrypoint /opt/coder "$IMAGE" templates edit vlsi-workspace --max-ttl 12h\n' >> "$tmp/max-ttl.sh"
expect "$tmp/max-ttl.sh" 1 "--max-ttl is caught"

# 3. The real script must pass.
expect "$src" 0 "the repository script passes"
