#!/usr/bin/env bash
# ── Coder workspace template: k8s names must not come from user input ──────
#
# The first real workspace build failed (2026-11-07) because the PVC/pod names
# were built from the owner's Entra username, which is MIXED CASE
# (`NghiaVT`, `SinhHPT`):
#
#   metadata.0.name a lowercase RFC 1123 subdomain must consist of lower case
#   alphanumeric characters, '-' or '.'
#
# Kubernetes object names use the workspace id (a UUID) instead; human names go
# into labels/annotations, where a label value must also be lower case,
# [a-z0-9_.-] and <= 63 chars. This check enforces the shape:
#   - no `name =` assignment may use .me.name as the object name;
#   - every `name = "coder-${local.workspace_id}..."` shape is required on the
#     PVC and pod;
#   - outside an `annotations` block, any use of .me.name must be wrapped in
#     lower( (i.e. it is a label value);
#   - the lock file carries hashes for more than one platform, so the
#     provisioner (linux_amd64) finds its own.
#
# Usage: scripts/check-coder-template-names.sh [MAIN_TF]
set -euo pipefail
cd "$(dirname "$0")/.."

FILE=${1:-platform/coder/templates/vlsi-workspace/main.tf}
LOCK=$(dirname "$FILE")/.terraform.lock.hcl
fail=0

[ -f "$FILE" ] || { echo "::error::missing $FILE"; exit 1; }

# 1. object names must not be built from .me.name
if grep -nE '^[[:space:]]*name[[:space:]]*=.*(coder_workspace\.me\.name|coder_workspace_owner\.me\.name)' "$FILE"; then
  echo "::error file=$FILE::an object name is built from .me.name; use local.workspace_id (see the header)"
  fail=1
fi

# 2. both the PVC and the pod name from the id
ids=$(grep -cE '^[[:space:]]*name[[:space:]]*=[[:space:]]*"coder-\$\{local\.workspace_id\}' "$FILE" || true)
if [ "$ids" -lt 2 ]; then
  echo "::error file=$FILE::expected the PVC and pod names to use local.workspace_id, found $ids"
  fail=1
fi

# 3. .me.name outside annotations must be lower()-cased (labels, other values)
if awk '
  /^[[:space:]]*annotations[[:space:]]*=[[:space:]]*\{/ { in_ann = 1 }
  in_ann && /^[[:space:]]*\}/ { in_ann = 0; next }
  /^[[:space:]]*#/ { next }
  !in_ann && /\.me\.name/ && !/lower\(/ { print FILENAME ":" NR ": " $0; bad = 1 }
  END { exit bad }
' "$FILE"; then :; else
  echo "::error file=$FILE::a .me.name value outside annotations is not wrapped in lower()"
  fail=1
fi

# 4. the lock file is multi-platform: the provisioner is linux/amd64
if [ -f "$LOCK" ]; then
  h1=$(grep -c '"h1:' "$LOCK" || true)
  if [ "$h1" -lt 4 ]; then
    echo "::error file=$LOCK::only $h1 h1 hashes: regenerate with terraform providers lock -platform=linux_amd64 -platform=linux_arm64 -platform=darwin_arm64"
    fail=1
  else
    echo "ok: lock file carries $h1 h1 hashes (multi-platform)"
  fi
fi

[ "$fail" -eq 0 ] && echo "ok: $FILE"
exit "$fail"
