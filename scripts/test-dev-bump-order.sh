#!/usr/bin/env bash
# Fixtures for scripts/dev-bump-order.sh and scripts/dev-bump-scope.sh.
#
# Runs in the dev-bump-merge workflow (before the guard) AND in PR CI
# (.github/workflows/dev-bump-order.yml): a broken selector must not keep
# merging the wrong PR, and a broken scope parser must not authorise a merge.
set -euo pipefail
cd "$(dirname "$0")/.."

order=scripts/dev-bump-order.sh
scope=scripts/dev-bump-scope.sh
pass=0

expect_order() { # expect_order <label> <expected stdout> <target> <product> <json>
  local label=$1 want=$2 target=$3 product=$4 json=$5 got
  got=$(printf '%s' "$json" | "$order" "$target" "$product" -)
  if [ "$got" = "$want" ]; then
    echo "  ok   $label"
    pass=$((pass + 1))
  else
    echo "  FAIL $label" >&2
    echo "       want: $(printf '%q' "$want")" >&2
    echo "       got:  $(printf '%q' "$got")" >&2
    exit 1
  fi
}

expect_order_status() { # expect_order_status <label> <status> <target> <product> <json>
  local label=$1 want=$2 target=$3 product=$4 json=$5 rc=0
  printf '%s' "$json" | "$order" "$target" "$product" - >/dev/null 2>&1 || rc=$?
  if [ "$rc" = "$want" ]; then
    echo "  ok   $label"
    pass=$((pass + 1))
  else
    echo "  FAIL $label (exit $rc, want $want)" >&2
    exit 1
  fi
}

expect_scope() { # expect_scope <label> <product|FAIL> <newline-separated files>
  local label=$1 want=$2 files=$3 got rc=0
  got=$(printf '%s\n' "$files" | "$scope" 2>/dev/null) || rc=$?
  if [ "$want" = "FAIL" ]; then
    [ "$rc" = "1" ] && { echo "  ok   $label"; pass=$((pass + 1)); return; }
  elif [ "$rc" = "0" ] && [ "$got" = "$want" ]; then
    echo "  ok   $label"
    pass=$((pass + 1))
    return
  fi
  echo "  FAIL $label (exit $rc, got '$got', want '$want')" >&2
  exit 1
}

# ── ordering: two products, three kb bumps, one rova bump ──────────────────────
two_products='[
  {"number": 193, "product": "kb"},
  {"number": 190, "product": "rova"},
  {"number": 192, "product": "kb"},
  {"number": 194, "product": "kb"}
]'

expect_order "newest kb supersedes the older two, newest first" \
  $'role=newest\nnewer=-\nolder=193 192\nmerged_ahead=-' 194 kb "$two_products"
expect_order "an older kb is refused and names the newer" \
  $'role=older\nnewer=194\nolder=\nmerged_ahead=-' 193 kb "$two_products"
expect_order "rova is newest among rova only, despite higher kb numbers" \
  $'role=newest\nnewer=-\nolder=\nmerged_ahead=-' 190 rova "$two_products"

one='[{"number": 201, "product": "opshub"}]'
expect_order "a lone bump is newest with nothing to supersede" \
  $'role=newest\nnewer=-\nolder=\nmerged_ahead=-' 201 opshub "$one"

# The newer bump MERGED but its close of this older one failed: merging this one
# now would roll dev back. `merged_ahead` is what refuses it.
merged_ahead='[
  {"number": 198, "product": "rova"},
  {"number": 200, "product": "rova", "state": "merged"},
  {"number": 205, "product": "kb", "state": "merged"}
]'
expect_order "a merged newer bump is reported even for the newest open PR" \
  $'role=newest\nnewer=-\nolder=\nmerged_ahead=200' 198 rova "$merged_ahead"
expect_order "an older merged bump does not block" \
  $'role=newest\nnewer=-\nolder=\nmerged_ahead=-' 201 rova \
  '[{"number":201,"product":"rova"},{"number":150,"product":"rova","state":"merged"}]'

expect_order_status "a closed/absent target is an error, not a merge" 2 999 kb "$two_products"
expect_order_status "a target for the wrong product is an error" 2 194 rova "$two_products"
expect_order_status "malformed JSON is refused" 2 194 kb '{"not":"an array"}'

# ── scope: the product, from the file list only ────────────────────────────────
expect_scope "dev tags + same render" rova \
  $'values/rova/tags.dev.yaml\nrendered/rova/dev.yaml'
expect_scope "dev tags alone" opshub 'values/opshub/tags.dev.yaml'
expect_scope "tags.prod.yaml is never in scope" FAIL 'values/rova/tags.prod.yaml'
expect_scope "render for a different product" FAIL \
  $'values/rova/tags.dev.yaml\nrendered/opshub/dev.yaml'
expect_scope "a second values product" FAIL \
  $'values/rova/tags.dev.yaml\nvalues/opshub/tags.dev.yaml'
expect_scope "any other path" FAIL \
  $'values/rova/tags.dev.yaml\ncharts/qnsc-service/Chart.yaml'
expect_scope "render without a values bump" FAIL 'rendered/rova/dev.yaml'
expect_scope "no files" FAIL ''

echo "dev-bump-order: $pass fixture(s) passed"
