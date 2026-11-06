#!/usr/bin/env bash
# check-coder-pin.sh — the Coder chart's pinned DIGEST still matches its tag.
#
# ArgoCD's Helm OCI source takes a TAG, not a digest, in targetRevision. A tag
# re-pushed upstream would therefore change what the next sync deploys with no
# git change at all. versions.yaml records the OCI manifest digest; this check
# re-reads it from the registry and fails loudly on a mismatch.
#
# Run in chart-ci on every platform PR and by the daily `coder-pin` job.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

block=$(sed -n '/^  coder:/,/^  [a-z-]*:/p' versions.yaml)
version=$(printf '%s\n' "$block" | sed -n 's/^    version: "\(.*\)"/\1/p')
digest=$(printf '%s\n' "$block" | sed -n 's/^    digest: "\(.*\)"/\1/p')
[ -n "$version" ] && [ -n "$digest" ] || {
  echo "::error::versions.yaml: the coder entry needs version and digest"; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
out=$(helm pull "oci://ghcr.io/coder/chart/coder" --version "$version" -d "$tmp" 2>&1)
printf '%s\n' "$out" | grep -qF "Digest: $digest" || {
  printf '%s\n' "$out"
  echo "::error::coder chart $version is not the digest pinned in versions.yaml ($digest) — the upstream tag was re-pushed. Review the new chart, then bump version+digest together."
  exit 1; }
echo "coder chart $version matches $digest"
