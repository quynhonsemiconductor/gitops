#!/usr/bin/env bash
# ── every namespace under platform/ must be a platform-project destination ──
#
# An AppProject bounds what its Applications may do. A namespaced object in a
# namespace the project does not list fails the sync with:
#
#   namespace <ns> is not permitted in project 'platform'
#
# and ArgoCD reports the Application OutOfSync, silently enough that the mistake
# reached main twice: the DCGM exporter moved into `gpu-monitoring` (gitops#385)
# and platform-ai could not sync until the destination was added (gitops#388).
#
# Every manifest under platform/ is deployed by an Application in the `platform`
# project (platform/*, apps/platform-*.yaml). Values files are not manifests and
# are skipped — the test is "the document has a column-0 `apiVersion:`", so a
# manifest embedded in a ConfigMap or a chart values list does not register.
# `kind: Namespace` definitions are cluster-scoped and need no destination.
#
# Usage: scripts/check-appproject-destinations.sh [ROOT]
set -euo pipefail

ROOT=${1:-$(cd "$(dirname "$0")/.." && pwd)}
PROJECT="$ROOT/apps/project-platform.yaml"
fail=0
checked=0

[ -f "$PROJECT" ] || { echo "::error::missing $PROJECT"; exit 1; }

dests=$(grep -oE 'namespace: [A-Za-z0-9-]+ *\}' "$PROJECT" \
          | sed -E 's/namespace: ([A-Za-z0-9-]+).*/\1/' | sort -u)
if [ -z "$dests" ]; then
  echo "::error::could not parse any destinations from $PROJECT"
  exit 1
fi

in_dests() { printf '%s\n' "$dests" | grep -qx "$1"; }

while IFS='|' read -r file ns; do
  [ -z "$ns" ] && continue
  checked=$((checked + 1))
  if in_dests "$ns"; then
    echo "ok: $ns ($file)"
  else
    echo "::error file=$file::metadata.namespace '$ns' is not a destination of the platform AppProject (apps/project-platform.yaml); the Application will fail with \"namespace $ns is not permitted in project 'platform'\""
    fail=1
  fi
done < <(find "$ROOT/platform" -name '*.yaml' -type f | sort | while IFS= read -r yaml; do
  # One awk per file: BSD awk has no multi-character RS, and a splitter that
  # only works under gawk would inspect nothing on a developer machine.
  awk '
    BEGIN { manifest = 0; kind = ""; ns = "" }
    function flush() {
      if (manifest && kind != "" && kind != "Namespace" && ns != "")
        print FILENAME "|" ns
      manifest = 0; kind = ""; ns = ""
    }
    /^---[[:space:]]*$/ { flush(); next }
    /^apiVersion:/ { manifest = 1 }
    /^kind:[ \t]*/ { k = $0; sub(/^kind:[ \t]*/, "", k); gsub(/[ \t"]/, "", k); kind = k }
    /^  namespace:[ \t]*/ { n = $0; sub(/^  namespace:[ \t]*/, "", n); gsub(/[ \t"]/, "", n); if (ns == "") ns = n }
    END { flush() }
  ' "$yaml"
done)

if [ "$checked" -eq 0 ]; then
  echo "::error::no namespaced manifest under $ROOT/platform was found: the check inspected nothing"
  exit 1
fi

exit "$fail"
