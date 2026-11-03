#!/usr/bin/env bash
# Render every (product, environment) Application to rendered/.
#
# §11c — THE GOLDEN RENDER IS THE CONTROL. Unit tests on a chart that serves
# fifteen services are necessary and not sufficient: the failure to catch is
# "this change silently removes the PodDisruptionBudget from every size-M
# service", which passes every unit test ever written.
#
# WHAT IS RENDERED — what ArgoCD will apply, not the chart at HEAD. Each
# Application pins its own chart in appsets/products.yaml (OCI + `targetRevision`),
# so this script reads the (product, env, chartVersion) rows from BOTH generators
# and renders with `oci://…/qnsc-service --version <chartVersion>`, passing the
# same three value files in the same order as the ApplicationSet template
# (base.yaml, <env>.yaml, tags.<env>.yaml). Rows that are commented out are
# skipped, exactly as ArgoCD skips them.
#
# A chart PR still needs its own preview: `./scripts/render.sh --head <dir>`
# renders the chart at HEAD for every enabled row into a directory that is NOT
# committed. chart-ci runs it and validates the output, so a chart change is
# tested before any Application pins it.
#
# Committing the pinned output means an appset/values change shows the exact
# manifest diff for every Application. The reviewer sees what production will
# look like instead of reasoning about what a template change implies.
set -euo pipefail
cd "$(dirname "$0")/.."

APPSSET=appsets/products.yaml
CHART_REPO=oci://ghcr.io/quynhonsemiconductor/charts
CHART_NAME=qnsc-service
HEAD_CHART=charts/qnsc-service

die() { echo "::error::$*" >&2; exit 1; }

# The (product, env, chartVersion) rows of both generators. The pattern anchors
# a list item at the start of the line, so a leading `#` (a disabled row) cannot
# match and is skipped.
rows() {
  sed -nE \
    's/^[[:space:]]*-[[:space:]]*\{[[:space:]]*product:[[:space:]]*([a-z0-9-]+),[[:space:]]*env:[[:space:]]*(dev|prod),[[:space:]]*chartVersion:[[:space:]]*"([^"]+)"[[:space:]]*\}[[:space:]]*$/\1 \2 \3/p' \
    "$APPSSET"
}

# Fail closed on a format this parser does not understand: a silently skipped
# row is an Application whose manifests nobody reviewed.
rows_list=$(rows)
row_count=$(printf '%s\n' "$rows_list" | sed '/^$/d' | wc -l | tr -d ' ')
declared=$(grep -cE '^[[:space:]]*-.*chartVersion:' "$APPSSET" || true)
[ "$declared" -eq "$row_count" ] || die \
  "appsets/products.yaml has $declared enabled chart row(s), parsed $row_count — update scripts/render.sh's row pattern."

usage() {
  echo "usage: $0 [--rows | --head <dir>]" >&2
  exit 2
}

render_one() { # product env out chart [helm args...]
  local product=$1 env=$2 out=$3 chart=$4
  shift 4
  local base="values/${product}/base.yaml"
  local envfile="values/${product}/${env}.yaml"
  local tags="values/${product}/tags.${env}.yaml"
  for f in "$base" "$envfile" "$tags"; do
    [ -f "$f" ] || die "rendered row ${product}/${env} needs $f (the ApplicationSet names it)."
  done
  mkdir -p "$(dirname "$out")"
  # ArgoCD's Helm release name is the Application name (`<product>-<env>`), not
  # the product: the rova-prod ComparisonError log shows `--name-template
  # rova-prod`. The chart derives every name from `.Values`, but the release name
  # must still match so anything Helm itself stamps does too.
  helm template "${product}-${env}" "$chart" "$@" \
    --namespace "${product}-${env}" \
    -f "$base" -f "$envfile" -f "$tags" \
    > "$out"
}

render_all() { # out_dir chart_for_row_fn
  local out_dir=$1 chart_for_row=$2
  local product env version
  rm -rf "$out_dir" && mkdir -p "$out_dir"
  while read -r product env version; do
    [ -n "$product" ] || continue
    local out="${out_dir}/${product}/${env}.yaml"
    # shellcheck disable=SC2086
    "$chart_for_row" "$product" "$env" "$version" "$out"
    echo "  rendered ${product}/${env}  ($(grep -c '^kind:' "$out") resources)"
  done <<< "$rows_list"
}

case "${1:-}" in
  --rows)
    [ $# -eq 1 ] || usage
    printf '%s\n' "$rows_list" | sed '/^$/d'
    ;;
  --head)
    [ $# -eq 2 ] || usage
    out_dir=$2
    pinned() { render_one "$1" "$2" "$4" "$HEAD_CHART"; }
    render_all "$out_dir" pinned
    echo "rendered the HEAD chart for $row_count Application(s) into ${out_dir} (not committed)"
    ;;
  "")
    pinned() {
      local product=$1 env=$2 version=$3 out=$4
      render_one "$product" "$env" "$out" "${CHART_REPO}/${CHART_NAME}" --version "$version"
    }
    render_all rendered pinned
    echo "rendered $row_count Application(s) at their pinned chart versions"
    ;;
  *)
    usage
    ;;
esac
