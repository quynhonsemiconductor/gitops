#!/usr/bin/env bash
# Fail when a prod ApplicationSet row is enabled while a values file still holds a
# `<..._PROD_...>` placeholder (e.g. MAIL_GRAPH_CLIENT_ID: "<ROVA_PROD_SERVICE_APP_ID>").
# A placeholder is fine while the row is disabled: the app refuses it at boot, but only
# after prod data has moved, so the PR that enables the row is the last safe stop.
set -euo pipefail
cd "$(dirname "$0")/.."
# an enabled prod element: an uncommented `- { product: ..., env: prod ...}` line
enabled=$(grep -E '^[[:space:]]*-[[:space:]]*\{[^}]*env:[[:space:]]*prod' appsets/products.yaml || true)
[ -n "$enabled" ] || { echo "prod row disabled: placeholders allowed"; exit 0; }
fail=0
for p in $(echo "$enabled" | sed -E 's/.*product:[[:space:]]*([a-z0-9-]+).*/\1/'); do
  if grep -nE '<[A-Z0-9_]*PROD[A-Z0-9_]*>' "values/$p/prod.yaml"; then
    echo "::error::values/$p/prod.yaml still holds a placeholder and the $p prod row is enabled"; fail=1
  fi
done
exit $fail
