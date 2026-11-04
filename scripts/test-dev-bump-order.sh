#!/usr/bin/env bash
# Fixtures for scripts/dev-bump-order.sh. Runs in dev-bump-merge.yml before the
# guard, so a broken selection cannot silently keep merging the wrong PR.
set -euo pipefail
cd "$(dirname "$0")/.."

script=scripts/dev-bump-order.sh
pass=0

expect() { # expect <label> <expected stdout> <target> <product> <json>
  local label=$1 want=$2 target=$3 product=$4 json=$5 got
  got=$(printf '%s' "$json" | "$script" "$target" "$product" -)
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

expect_status() { # expect_status <label> <status> <target> <product> <json>
  local label=$1 want=$2 target=$3 product=$4 json=$5 rc=0
  printf '%s' "$json" | "$script" "$target" "$product" - >/dev/null 2>&1 || rc=$?
  if [ "$rc" = "$want" ]; then
    echo "  ok   $label"
    pass=$((pass + 1))
  else
    echo "  FAIL $label (exit $rc, want $want)" >&2
    exit 1
  fi
}

# Two products; three kb bumps arrive out of order, one rova bump.
two_products='[
  {"number": 193, "product": "kb"},
  {"number": 190, "product": "rova"},
  {"number": 192, "product": "kb"},
  {"number": 194, "product": "kb"}
]'

expect "newest kb supersedes the older two, newest first" \
  $'role=newest\nnewer=-\nolder=193 192' 194 kb "$two_products"
expect "an older kb is refused and names the newer" \
  $'role=older\nnewer=194\nolder=' 193 kb "$two_products"
expect "rova is newest among rova only, despite higher kb numbers" \
  $'role=newest\nnewer=-\nolder=' 190 rova "$two_products"

one='[{"number": 201, "product": "opshub"}]'
expect "a lone bump is newest with nothing to supersede" \
  $'role=newest\nnewer=-\nolder=' 201 opshub "$one"

expect_status "a closed/absent target is an error, not a merge" 2 999 kb "$two_products"
expect_status "a target for the wrong product is an error" 2 194 rova "$two_products"
expect_status "malformed JSON is refused" 2 194 kb '{"not":"an array"}'

echo "dev-bump-order: $pass fixture(s) passed"
