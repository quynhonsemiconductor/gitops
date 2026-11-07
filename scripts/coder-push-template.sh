#!/usr/bin/env bash
# coder-push-template.sh — owner-run: push platform/coder/templates/vlsi-workspace
# to the Coder deployment. The UI copy is NEVER the source of truth: this script
# overwrites it on every run, so a hand edit in the UI is invisible in review and
# is lost at the next push (design §5.1).
#
#   export CODER_URL=https://coder.qnsc.vn          # over WARP
#   export CODER_SESSION_TOKEN=...                  # `coder tokens create`, never committed
#                                                   # (CODER_TOKEN is accepted as an alias)
#   export VLSI_NODE_SSH=qnsc@vlsi-01               # the storage-gate node
#   ./scripts/coder-push-template.sh
#
# The token is read from the environment and passed to the pinned coder image by
# NAME only (`-e CODER_SESSION_TOKEN`), so the value never enters argv, a shell
# history line or the output. A CI job can use the same script with the token
# delivered by ESO.
#
# The CLI reads CODER_SESSION_TOKEN, not CODER_TOKEN (`coder --help`:
# "--token string, $CODER_SESSION_TOKEN"). The owner-facing CODER_TOKEN is kept
# as an alias and translated here, so a wrong env name cannot silently run the
# CLI unauthenticated (the 2026-11-07 "You are signed out" failure).
#
# STORAGE GATE: local-path enforces no size, and vlsi-01's homes must land on the
# 300 GB data disk (sdb), not the 40 GB root. The push REFUSES until
# `findmnt` on the node shows sdb at the local-path path. F mounts it in the
# #428 window; until then no template and no pilot.
#
# The Coder CLI runs in the digest-pinned server image (no local install):
#   ghcr.io/coder/coder:v2.38.6@sha256:...  (versions.yaml, `coder.image`)
# The template directory carries .terraform.lock.hcl (generated with
# `terraform init -backend=false`), so the push does not warn about unpinned
# providers; re-run that command and commit the lock file when a provider moves.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_DIR="$ROOT/platform/coder/templates/vlsi-workspace"
IMAGE="ghcr.io/coder/coder:v2.38.6@sha256:c9245405c482ede17699d65deb8c21488a17feff5497fc84d6a350c395da2bdd"   # versions.yaml (image)
NAME="vlsi-workspace"

: "${CODER_URL:?set CODER_URL (https://coder.qnsc.vn, over WARP)}"
CODER_SESSION_TOKEN="${CODER_SESSION_TOKEN:-${CODER_TOKEN:-}}"
export CODER_SESSION_TOKEN
: "${CODER_SESSION_TOKEN:?set CODER_SESSION_TOKEN (coder tokens create; CODER_TOKEN accepted as an alias), never commit it}"
[[ -f "$TEMPLATE_DIR/main.tf" ]] || { echo "STOP: $TEMPLATE_DIR/main.tf not found" >&2; exit 1; }

# ── storage gate (see the header) ────────────────────────────────────────────
: "${VLSI_NODE_SSH:?set VLSI_NODE_SSH (e.g. qnsc@vlsi-01): the node whose local-path storage must be on sdb}"
mount="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$VLSI_NODE_SSH" \
  'findmnt -rno SOURCE,FSTYPE,TARGET --target /var/lib/rancher/k3s/storage' 2>/dev/null)" \
  || { echo "STOP: cannot read the mount table on $VLSI_NODE_SSH (findmnt failed)" >&2; exit 1; }
printf '%s\n' "$mount" | grep -Eq '/dev/sdb' \
  || { echo "STOP: /var/lib/rancher/k3s/storage on $VLSI_NODE_SSH is not on /dev/sdb (got: $mount). local-path enforces no size; a pilot now would fill the 40 GB root. Wait for the #428 mount." >&2; exit 1; }
echo "storage gate: local-path on sdb ($mount)"

# The image ENTRYPOINT is ["/opt/coder","server"], so every CLI call must
# override it and must NOT repeat the `coder` word: `docker run IMAGE coder
# templates ...` becomes `coder server coder templates ...`.
#
# The template goes in over STDIN (`--directory -`), not a bind mount: nothing
# in the host directory is writable from the container, and a future CLI that
# wants to write (a lock file, for example) cannot touch the git tree.
tar -C "$TEMPLATE_DIR" -cf - . \
  | docker run --rm -i \
      --entrypoint /opt/coder \
      -e CODER_URL -e CODER_SESSION_TOKEN \
      "$IMAGE" \
      templates push "$NAME" \
        --directory - \
        --yes \
        --activate

# TTL is template metadata, not HCL: 2 h default, reset by the agent's activity
# bump. There is NO hard ceiling on OSS 2.38.6: `--max-ttl` is not in
# `templates edit --help` (checked on the pinned image), so a max TTL is a
# Premium/UI feature and the 2 h default + bump is the policy. Re-running is
# idempotent.
docker run --rm \
  --entrypoint /opt/coder \
  -e CODER_URL -e CODER_SESSION_TOKEN \
  "$IMAGE" \
  templates edit "$NAME" --default-ttl 2h

echo "pushed $NAME from $TEMPLATE_DIR (TTL 2h default + activity bump). The UI copy is not the source."
