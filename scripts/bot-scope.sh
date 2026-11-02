#!/usr/bin/env bash
# bot-scope: a PR opened by the automation bot may merge without a human approval ONLY if it
# changes nothing but values/<product>/tags.dev.yaml. Anything else needs a current-head
# approval from a human with write access.
#
#   env: REPO (owner/name), PR (number), HEAD_SHA, AUTHOR (PR author login), GH_TOKEN
#        BOT_LOGIN (default qnsc-automation[bot])
#
# Fails closed: any API error, an empty file list, or an unreadable permission is a FAIL.
set -euo pipefail
: "${REPO:?}" "${PR:?}" "${HEAD_SHA:?}" "${AUTHOR:?}"
BOT_LOGIN=${BOT_LOGIN:-qnsc-automation[bot]}

if [ "$AUTHOR" != "$BOT_LOGIN" ]; then
  echo "bot-scope: PR author is $AUTHOR, not the bot: not applicable (pass)."
  exit 0
fi

files=$(gh api --paginate "repos/$REPO/pulls/$PR/files" --jq '.[] | .filename, (.previous_filename // empty)')
if [ -n "$files" ] && ! grep -Evq '^values/[^/]+/tags\.dev\.yaml$' <<<"$files"; then
  echo "bot-scope: bot PR touches only values/*/tags.dev.yaml (pass)."
  exit 0
fi
echo "bot-scope: bot PR touches files outside values/*/tags.dev.yaml (or has no files); needs a human approval:"
sed 's/^/  /' <<<"$files"

# Latest decisive review per user (COMMENTED/PENDING do not change an approval), on THIS head sha.
reviews=$(gh api --paginate "repos/$REPO/pulls/$PR/reviews" \
  --jq '.[] | select(.state=="APPROVED" or .state=="CHANGES_REQUESTED" or .state=="DISMISSED")
        | [.submitted_at, .user.login, .user.type, .state, .commit_id] | @tsv')
approvers=$(sort <<<"$reviews" | awk -F'\t' -v head="$HEAD_SHA" -v bot="$BOT_LOGIN" '
  NF { last[$2]=$4; type[$2]=$3; sha[$2]=$5 }
  END { for (u in last) if (last[u]=="APPROVED" && sha[u]==head && type[u]!="Bot" && u!=bot) print u }')

for u in $approvers; do
  perm=$(gh api "repos/$REPO/collaborators/$u/permission" --jq .permission 2>/dev/null || true)
  case $perm in
    admin|maintain|write) echo "bot-scope: approved by $u ($perm) on ${HEAD_SHA:0:12} (pass)."; exit 0 ;;
    *) echo "bot-scope: approval by $u ignored (permission: ${perm:-unreadable})." ;;
  esac
done
echo "::error::bot-scope: this bot PR changes more than values/*/tags.dev.yaml and has no current approval from a human with write access on ${HEAD_SHA:0:12}. Approve it (a new push needs a new approval)."
exit 1
