#!/usr/bin/env bash
# Which of the dev-bump PRs for a product may merge?
#
# Bump PRs pile up: the matrix pushes several tags before any merges, so kb had
# #192 #193 #194 #195 open at once. Each merge workflow used to merge whichever
# PR's checks finished first, so an OLDER bump could land after a newer one and
# roll dev back to an older sha.
#
# PURE selection logic, no GitHub calls: the caller supplies the PRs as JSON on
# stdin, each `{number, product, state}` (state defaults to "open"). PR NUMBER is
# the order — it is monotonic, and the bump job is serialised per product in
# commit order, so a higher number is a later commit. createdAt is not used: it
# can skew, and it is not what the matrix sequences.
#
#   dev-bump-order.sh <target-pr> <product> -
#
# Output (one per line):
#   role=newest|older
#   newer=<pr-number|->           newest OPEN bump when role=older
#   older=<space-separated>       OPEN PRs a newest target supersedes (newest first)
#   merged_ahead=<pr-number|->    a MERGED bump for this product with a HIGHER
#                                 number: even if this PR is the newest open one,
#                                 merging it would roll dev back
#
# Exit 2 when the target is absent from the open list: it was closed or merged
# between the caller's query and this decision, so nobody should act on it.
set -euo pipefail

target=${1:?usage: dev-bump-order.sh <target-pr> <product> -}
product=${2:?usage: dev-bump-order.sh <target-pr> <product> -}
source=${3:?usage: dev-bump-order.sh <target-pr> <product> -}
[ "$source" = "-" ] || { echo "only '-' (stdin) is supported" >&2; exit 2; }

[[ "$target" =~ ^[0-9]+$ ]] || { echo "target-pr must be numeric" >&2; exit 2; }
[[ "$product" =~ ^[a-z0-9-]+$ ]] || { echo "product must be lowercase alnum/dash" >&2; exit 2; }

json=$(cat)
jq -e 'type == "array" and all(.[]; (.number|type)=="number")' <<<"$json" >/dev/null 2>&1 \
  || { echo "stdin must be a JSON array of {number, ...}" >&2; exit 2; }

# `state` absent means open; anything else is explicit.
norm='map(. + {state: (.state // "open")})'

if ! jq -e --argjson t "$target" --arg p "$product" \
    "($norm) | any(.[]; .number == \$t and .product == \$p and .state == \"open\")" <<<"$json" >/dev/null; then
  echo "target #$target is not an open bump for $product" >&2
  exit 2
fi

newest=$(jq -r --arg p "$product" "($norm) | [.[] | select(.product == \$p and .state == \"open\") | .number] | max" <<<"$json")
merged_ahead=$(jq -r --arg p "$product" --argjson t "$target" \
  "($norm) | [.[] | select(.product == \$p and .state == \"merged\" and .number > \$t) | .number] | max // \"-\"" <<<"$json")

if [ "$target" -eq "$newest" ]; then
  older=$(jq -r --arg p "$product" --argjson t "$target" \
    "($norm) | [.[] | select(.product == \$p and .state == \"open\" and .number < \$t) | .number] | sort | reverse | map(tostring) | join(\" \")" <<<"$json")
  echo "role=newest"
  echo "newer=-"
  echo "older=$older"
else
  echo "role=older"
  echo "newer=$newest"
  echo "older="
fi
echo "merged_ahead=$merged_ahead"
