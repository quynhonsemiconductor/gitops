#!/usr/bin/env bash
# Which of the open dev-bump PRs for a product may merge?
#
# Bump PRs pile up: the matrix pushes several tags before any merges, so kb had
# #192 #193 #194 #195 open at once. Each merge workflow used to merge whichever
# PR's checks finished first, so an OLDER bump could land after a newer one and
# roll dev back to an older sha.
#
# PURE selection logic, no GitHub calls: the caller supplies the open bumps as
# JSON on stdin. PR NUMBER is the order — it is monotonic and cannot be
# back-dated the way createdAt can be skew. Only entries for PRODUCT count, so
# another product's newer PR never supersedes this one.
#
#   dev-bump-order.sh <target-pr> <product> -      # JSON on stdin
#
# Output (one per line):
#   role=newest|older
#   newer=<pr-number|->       the newest open bump when role=older
#   older=<space-separated>   the PRs a newest target supersedes (newest first)
#
# Exit 2 when the target is absent from the list: it was closed or merged
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

if ! jq -e --argjson t "$target" --arg p "$product" \
    'any(.[]; .number == $t and .product == $p)' <<<"$json" >/dev/null; then
  echo "target #$target is not an open bump for $product" >&2
  exit 2
fi

newest=$(jq -r --arg p "$product" '[.[] | select(.product == $p) | .number] | max' <<<"$json")

if [ "$target" -eq "$newest" ]; then
  older=$(jq -r --arg p "$product" --argjson t "$target" \
    '[.[] | select(.product == $p and .number < $t) | .number] | sort | reverse | map(tostring) | join(" ")' <<<"$json")
  echo "role=newest"
  echo "newer=-"
  echo "older=$older"
else
  echo "role=older"
  echo "newer=$newest"
  echo "older="
fi
