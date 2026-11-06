#!/usr/bin/env bash
# ── barman retention must stay BELOW the R2 lifecycle ───────────────────────
#
# The two retention controls are independent:
#   - CNPG/barman `ObjectStore.spec.retentionPolicy` decides which base backups
#     and WAL barman PRUNES and which it still LISTS as restorable;
#   - the R2 bucket lifecycle (infra live/onprem/backups.tf, infra#459) DELETES
#     objects at 30 days on qnsc-backups, whatever barman thinks.
#
# If barman's retention reaches the lifecycle's age, the lifecycle can delete
# the oldest base backup — or WAL that barman still needs — while barman still
# lists it. The oldest restore point then fails at the moment it matters. The
# lifecycle is the BACKSTOP; barman must sit well below it. The design value is
# 14 days, which is also the Bucket Lock window.
#
# Checked here statically because neither control lives in the other's repo:
# this repository owns every ObjectStore, infra owns every lifecycle rule.
# R2_LIFECYCLE_DAYS mirrors the infra value; bump it together with infra#459.
#
# Usage: scripts/check-barman-retention.sh [ROOT]   (default: repository root)
set -euo pipefail

ROOT=${1:-$(cd "$(dirname "$0")/.." && pwd)}
LIFECYCLE_DAYS=${R2_LIFECYCLE_DAYS:-30}
fail=0
checked=0

if [ ! -d "$ROOT/platform" ]; then
  echo "::error::no platform/ directory under $ROOT"
  exit 1
fi

# Multi-document YAML, parsed by record: an ObjectStore doc is the only kind
# that may carry retentionPolicy. 2-space indentation is the repo's shape.
while IFS='|' read -r file ns name dest retention; do
  [ -z "$name" ] && continue

  # The restore-test ObjectStores are read-only mirrors of the archive and must
  # never prune; they deliberately carry no retentionPolicy.
  [ "$ns" = "restore-test" ] && continue

  # Only the prod bucket has the checked lifecycle. The dev bucket
  # (qnsc-backups-dev) has its own 7-day rule and no barman (dump-only).
  case "$dest" in
    s3://qnsc-backups/*) ;;
    *) continue ;;
  esac

  where="$ns/$name ($file)"
  checked=$((checked + 1))
  if [ -z "$retention" ]; then
    echo "::error file=$file::ObjectStore $where sets no retentionPolicy: barman would never prune, so its list would outlive the ${LIFECYCLE_DAYS}-day R2 lifecycle"
    fail=1
    continue
  fi

  days=${retention%d}
  case "$days" in
    ''|*[!0-9]*)
      echo "::error file=$file::ObjectStore $where has retentionPolicy '$retention', not '<days>d'"
      fail=1
      continue
      ;;
  esac

  if [ "$days" -ge "$LIFECYCLE_DAYS" ]; then
    echo "::error file=$file::ObjectStore $where retentionPolicy $retention must be BELOW the ${LIFECYCLE_DAYS}-day R2 lifecycle: the lifecycle would delete the oldest base backup/WAL while barman still lists it"
    fail=1
  else
    echo "ok: $where retentionPolicy $retention < ${LIFECYCLE_DAYS}d lifecycle"
  fi
done < <(find "$ROOT/platform" -name '*.yaml' -type f | sort | while IFS= read -r yaml; do
  # One awk per file: BSD awk (macOS) has no multi-character RS, and a
  # document splitter that only works under gawk is a check that silently
  # matches nothing on a developer machine.
  awk '
    function flush() {
      if (buf !~ /kind:[ \t]*ObjectStore/) { buf = ""; return }
      ns = ""; name = ""; dest = ""; retention = ""
      n = split(buf, L, "\n")
      for (i = 1; i <= n; i++) {
        l = L[i]
        if (l ~ /^  namespace:/)               { sub(/^  namespace:[ \t]*/, "", l); ns = l }
        else if (l ~ /^  name:/ && name == "") { sub(/^  name:[ \t]*/, "", l); name = l }
        else if (l ~ /^[ \t]*destinationPath:/) { sub(/^[ \t]*destinationPath:[ \t]*/, "", l); dest = l }
        else if (l ~ /^  retentionPolicy:/)    { sub(/^  retentionPolicy:[ \t]*/, "", l); retention = l }
      }
      gsub(/["[:space:]]/, "", ns); gsub(/["[:space:]]/, "", name)
      gsub(/["[:space:]]/, "", dest); gsub(/["[:space:]]/, "", retention)
      print FILENAME "|" ns "|" name "|" dest "|" retention
      buf = ""
    }
    /^---[[:space:]]*$/ { flush(); next }
    { buf = buf $0 "\n" }
    END { flush() }
  ' "$yaml"
done)

if [ "$checked" -eq 0 ]; then
  echo "::error::no barman ObjectStore on s3://qnsc-backups/ was found under $ROOT/platform: the check inspected nothing"
  exit 1
fi

exit "$fail"
