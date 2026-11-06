#!/usr/bin/env bash
# coder-push-template.sh — owner-run: push platform/coder/templates/vlsi-workspace
# to the Coder deployment. The UI copy is NEVER the source of truth: this script
# overwrites it on every run, so a hand edit in the UI is invisible in review and
# is lost at the next push (design §5.1).
#
#   export CODER_URL=https://coder.qnsc.vn          # over WARP
#   export CODER_TOKEN=...                          # `coder tokens create`, never committed
#   ./scripts/coder-push-template.sh
#
# The token is read from the environment and passed to the pinned coder image by
# name (`-e CODER_TOKEN`), so it never enters argv, a shell history line or the
# output. A CI job can use the same script with the token delivered by ESO.
#
# STORAGE GATE: local-path enforces no size, and vlsi-01's homes must land on the
# 300 GB data disk (sdb), not the 40 GB root. The push REFUSES until
# `findmnt` on the node shows sdb at the local-path path. F mounts it in the
# #428 window; until then no template and no pilot.
#
# The Coder CLI runs in the digest-pinned server image (no local install):
#   ghcr.io/coder/coder:v2.38.1@sha256:...  (versions.yaml, `coder.image`)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_DIR="$ROOT/platform/coder/templates/vlsi-workspace"
IMAGE="ghcr.io/coder/coder:v2.38.1@sha256:fcddd64d5f08d6aa8806508d1459d36f3e9e9098554440acd6dc2526a95252cc"   # versions.yaml (image)
NAME="vlsi-workspace"

: "${CODER_URL:?set CODER_URL (https://coder.qnsc.vn, over WARP)}"
: "${CODER_TOKEN:?set CODER_TOKEN (coder tokens create), never commit it}"
[[ -f "$TEMPLATE_DIR/main.tf" ]] || { echo "STOP: $TEMPLATE_DIR/main.tf not found" >&2; exit 1; }

# ── storage gate (see the header) ────────────────────────────────────────────
: "${VLSI_NODE_SSH:?set VLSI_NODE_SSH (e.g. qnsc@vlsi-01): the node whose local-path storage must be on sdb}"
mount="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$VLSI_NODE_SSH" \
  'findmnt -rno SOURCE,FSTYPE,TARGET --target /var/lib/rancher/k3s/storage' 2>/dev/null)" \
  || { echo "STOP: cannot read the mount table on $VLSI_NODE_SSH (findmnt failed)" >&2; exit 1; }
printf '%s\n' "$mount" | grep -Eq '/dev/sdb' \
  || { echo "STOP: /var/lib/rancher/k3s/storage on $VLSI_NODE_SSH is not on /dev/sdb (got: $mount). local-path enforces no size; a pilot now would fill the 40 GB root. Wait for the #428 mount." >&2; exit 1; }
echo "storage gate: local-path on sdb ($mount)"

docker run --rm \
  -e CODER_URL -e CODER_TOKEN \
  -v "$TEMPLATE_DIR:/tpl:ro" \
  "$IMAGE" \
  coder templates push "$NAME" \
    --directory /tpl \
    --yes \
    --activate

# TTL is template metadata, not HCL: 2 h default with the agent's activity bump,
# 12 h hard ceiling. Re-running is idempotent.
docker run --rm \
  -e CODER_URL -e CODER_TOKEN \
  "$IMAGE" \
  coder templates edit "$NAME" --default-ttl 2h --max-ttl 12h

echo "pushed $NAME from $TEMPLATE_DIR (TTL 2h/12h). The UI copy is not the source."
