#!/usr/bin/env bash
# Tests for scripts/bot-scope.sh with a stub `gh` serving fixture JSON. No network.
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
# gh api [--paginate] <path> --jq <expr>: apply the jq expression to the fixture for that path.
path=; jq_expr=
while [ $# -gt 0 ]; do
  case $1 in api|--paginate) ;; --jq) jq_expr=$2; shift ;; *) path=$1 ;; esac
  shift
done
case $path in
  */pulls/*/files)    f=$FIX/files.json ;;
  */pulls/*/reviews)  f=$FIX/reviews.json ;;
  */collaborators/*/permission) u=${path#*collaborators/}; u=${u%/permission}; f=$FIX/perm-$u.json
                      [ -f "$f" ] || { echo "404" >&2; exit 1; } ;;
  *) echo "unexpected path $path" >&2; exit 2 ;;
esac
jq -r "$jq_expr" "$f"
STUB
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH" REPO=o/r PR=1 HEAD_SHA=aaa111 GH_TOKEN=x

fail=0
run() { # run <name> <expect 0|1> <expected output substring>; fixtures already in $FIX
  local out rc=0
  out=$(AUTHOR=${AUTHOR:-qnsc-automation[bot]} ./scripts/bot-scope.sh 2>&1) || rc=$?
  if [ "$rc" = "$2" ] && grep -qF -- "$3" <<<"$out"; then echo "ok   $1"
  else echo "FAIL $1 (rc=$rc, wanted $2 / '$3')"; echo "$out" | sed 's/^/     /'; fail=1; fi
}
newcase() { FIX=$T/$1; export FIX; mkdir -p "$FIX"; echo "$2" > "$FIX/files.json"; echo "${3:-[]}" > "$FIX/reviews.json"; }
files() { jq -nc --argjson n "$(printf '%s\n' "$@" | jq -R . | jq -sc .)" '$n | map({filename: .})'; }
rev() { jq -nc --arg u "$1" --arg t "${5:-User}" --arg s "$2" --arg c "$3" --arg at "$4" '{submitted_at:$at,user:{login:$u,type:$t},state:$s,commit_id:$c}'; }
perm() { echo "{\"permission\":\"$2\"}" > "$FIX/perm-$1.json"; }
reviews() { printf '%s\n' "$@" | jq -sc .; }

# 1. human author: not applicable
newcase human "$(files charts/qnsc-service/Chart.yaml)"
AUTHOR=someone run "human author passes" 0 "not applicable"

# 2. bot, tags.dev.yaml only (also several products)
newcase botdev "$(files values/rova/tags.dev.yaml values/opshub/tags.dev.yaml)"
run "bot touching only tags.dev.yaml passes" 0 "only values/*/tags.dev.yaml"

# 3. bot, tags.prod.yaml: scope violation, no review
newcase botprod "$(files values/rova/tags.prod.yaml)"
run "bot touching tags.prod.yaml fails without approval" 1 "no current approval"
# 3b. mixed
newcase botmixed "$(files values/rova/tags.dev.yaml appsets/products.yaml)"
run "bot with one extra file fails" 1 "no current approval"
# 3c. look-alike paths
newcase botlook "$(files values/rova/x/tags.dev.yaml)"
run "nested look-alike path fails" 1 "no current approval"
newcase botlook2 "$(files values/rova/tags.dev.yaml.bak)"
run "suffix look-alike path fails" 1 "no current approval"
# 3d. empty file list fails closed
newcase botempty "[]"
run "empty file list fails closed" 1 "no current approval"

# 3e. the bump action re-renders in the same commit: rendered/<product>/dev.yaml passes ONLY with that product's tags.dev.yaml
newcase rtags "$(files values/rova/tags.dev.yaml rendered/rova/dev.yaml)"
run "tags + rendered, same product, passes" 0 "matching rendered"
newcase rtags2 "$(files values/rova/tags.dev.yaml values/opshub/tags.dev.yaml rendered/rova/dev.yaml rendered/opshub/dev.yaml)"
run "two products, each with its own rendered file, passes" 0 "matching rendered"
newcase ralone "$(files rendered/rova/dev.yaml)"
run "rendered alone fails" 1 "no current approval"
newcase rother "$(files values/rova/tags.dev.yaml rendered/opshub/dev.yaml)"
run "rendered of ANOTHER product fails" 1 "no current approval"
newcase rprod "$(files values/rova/tags.dev.yaml rendered/rova/prod.yaml)"
run "prod rendered file fails even with a dev tags file" 1 "no current approval"
newcase rprodtags "$(files values/rova/tags.prod.yaml rendered/rova/prod.yaml)"
run "prod tags + prod rendered fails" 1 "no current approval"
newcase rnested "$(files values/rova/tags.dev.yaml rendered/rova/x/dev.yaml)"
run "nested rendered look-alike fails" 1 "no current approval"
newcase rsuffix "$(files values/rova/tags.dev.yaml rendered/rova/dev.yaml.bak)"
run "suffix rendered look-alike fails" 1 "no current approval"
newcase rplus "$(files values/rova/tags.dev.yaml rendered/rova/dev.yaml charts/qnsc-service/Chart.yaml)"
run "tags + rendered + a chart file fails" 1 "no current approval"
newcase rren '[{"filename":"rendered/rova/dev.yaml","previous_filename":"rendered/rova/old.yaml"},{"filename":"values/rova/tags.dev.yaml"}]'
run "a rename out of an unlisted path fails" 1 "no current approval"
# a human approval still rescues an out-of-scope bot PR that includes rendered files
newcase rappr "$(files values/rova/tags.prod.yaml rendered/rova/prod.yaml)" "$(reviews "$(rev alice APPROVED aaa111 2026-11-02T10:00:00Z)")"
perm alice write
run "prod render + prod tags pass with a writer's approval" 0 "approved by alice"

# 4. approval by write user on head passes
newcase appr "$(files values/rova/tags.prod.yaml)" "$(reviews "$(rev alice APPROVED aaa111 2026-11-02T10:00:00Z)")"
perm alice write
run "approval by a writer on the head passes" 0 "approved by alice"
# 4b. approval on an old sha
newcase stale "$(files values/rova/tags.prod.yaml)" "$(reviews "$(rev alice APPROVED old000 2026-11-02T10:00:00Z)")"
perm alice write
run "approval on an old head fails" 1 "no current approval"
# 4c. approve then changes requested (latest wins)
newcase flip "$(files values/rova/tags.prod.yaml)" "$(reviews "$(rev alice APPROVED aaa111 2026-11-02T10:00:00Z)" "$(rev alice CHANGES_REQUESTED aaa111 2026-11-02T11:00:00Z)")"
perm alice write
run "later changes-requested cancels the approval" 1 "no current approval"
# 4d. approval then a plain comment still counts
newcase cmt "$(files values/rova/tags.prod.yaml)" "$(reviews "$(rev alice APPROVED aaa111 2026-11-02T10:00:00Z)" "$(rev alice COMMENTED aaa111 2026-11-02T11:00:00Z)")"
perm alice write
run "a later comment does not cancel the approval" 0 "approved by alice"
# 4e. dismissed approval
newcase dism "$(files values/rova/tags.prod.yaml)" "$(reviews "$(rev alice APPROVED aaa111 2026-11-02T10:00:00Z)" "$(rev alice DISMISSED aaa111 2026-11-02T11:00:00Z)")"
perm alice write
run "dismissed approval fails" 1 "no current approval"
# 4f. approver without write access / unreadable permission
newcase noperm "$(files values/rova/tags.prod.yaml)" "$(reviews "$(rev bob APPROVED aaa111 2026-11-02T10:00:00Z)")"
perm bob read
run "approval from a read-only user is ignored" 1 "permission: read"
newcase unread "$(files values/rova/tags.prod.yaml)" "$(reviews "$(rev carol APPROVED aaa111 2026-11-02T10:00:00Z)")"
run "unreadable permission fails closed" 1 "unreadable"
# 4g. bot self-approval and Bot-type reviewers never count
newcase self "$(files values/rova/tags.prod.yaml)" "$(reviews "$(rev 'qnsc-automation[bot]' APPROVED aaa111 2026-11-02T10:00:00Z Bot)" "$(rev 'other[bot]' APPROVED aaa111 2026-11-02T10:00:00Z Bot)")"
perm 'qnsc-automation[bot]' write; perm 'other[bot]' write
run "bot approvals do not count" 1 "no current approval"

exit $fail
