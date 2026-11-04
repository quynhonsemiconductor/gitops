#!/usr/bin/env bash
# Which product does a dev-bump PR bump, and is its file list allowed?
#
# PURE, no GitHub calls: the caller pipes the PR's changed filenames, one per
# line, on stdin. Prints the product on success (exit 0); prints the reason on
# stderr and exits 1 otherwise. Shared by the merge workflow and its fixtures so
# the thing that authorises a bot merge is the thing that is tested.
#
# ALLOWED: values/<product>/tags.dev.yaml
#          rendered/<product>/dev.yaml           (the bump action re-renders it)
#          both, same product, at least one values file
# PROD IS NEVER IN SCOPE: tags.prod.yaml and rendered/<p>/prod.yaml are refused.
set -euo pipefail

fail() { echo "$*" >&2; exit 1; }

values_product=""
rendered_product=""
count=0

while IFS= read -r f || [ -n "$f" ]; do
  [ -n "$f" ] || continue
  count=$((count + 1))
  if [[ "$f" =~ ^values/([a-z0-9-]+)/tags\.dev\.yaml$ ]]; then
    p=${BASH_REMATCH[1]}
    [ -z "$values_product" ] || [ "$values_product" = "$p" ] \
      || fail "two products: $values_product and $p"
    values_product=$p
  elif [[ "$f" =~ ^rendered/([a-z0-9-]+)/dev\.yaml$ ]]; then
    p=${BASH_REMATCH[1]}
    [ -z "$rendered_product" ] || [ "$rendered_product" = "$p" ] \
      || fail "two rendered products: $rendered_product and $p"
    rendered_product=$p
  else
    fail "out-of-scope path: $f"
  fi
done

[ "$count" -gt 0 ] || fail "no files"
[ -n "$values_product" ] || fail "no values/<product>/tags.dev.yaml"
[ -z "$rendered_product" ] || [ "$rendered_product" = "$values_product" ] \
  || fail "renders $rendered_product but bumps $values_product"

echo "$values_product"
