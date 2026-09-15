#!/usr/bin/env bash
# Render every (product, environment) to rendered/.
#
# §11c — THE GOLDEN RENDER IS THE CONTROL. Unit tests on a chart that serves
# fifteen services are necessary and not sufficient: the failure to catch is
# "this change silently removes the PodDisruptionBudget from every size-M
# service", which passes every unit test ever written.
#
# Committing the output means a chart pull request shows the exact manifest diff
# for every Application. The reviewer sees what production will look like instead
# of reasoning about what a template change implies.
set -euo pipefail
cd "$(dirname "$0")/.."

CHART=charts/qnsc-service
rm -rf rendered && mkdir -p rendered

for base in values/*/base.yaml; do
  product=$(basename "$(dirname "$base")")
  for env in dev prod; do
    envfile="values/${product}/${env}.yaml"
    [ -f "$envfile" ] || continue        # §5c — a prod-only product has no dev.yaml
    mkdir -p "rendered/${product}"
    helm template "$product" "$CHART" \
      --namespace "$product" \
      -f "$base" -f "$envfile" -f "values/${product}/tags.${env}.yaml" \
      > "rendered/${product}/${env}.yaml"
    echo "  rendered ${product}/${env}  ($(grep -c '^kind:' "rendered/${product}/${env}.yaml") resources)"
  done
done
