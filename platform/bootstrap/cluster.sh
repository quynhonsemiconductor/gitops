#!/usr/bin/env bash
# Bootstrap a cluster from git. The SA runs this; the OWNER runs secrets.sh first.
#
# It is steps 1-5 of platform/argocd/bootstrap.md as one idempotent script:
#
#   1  namespaces            platform/namespaces/{external-secrets,argocd,onprem}.yaml
#   2  ESO credentials       the service-principal Secrets the ClusterSecretStores read
#   3  CNPG CA               ONE Key Vault read -> pg-<env>-ca and pg-<env>-ca-pub
#   4  ArgoCD                helm, version from versions.yaml (no yq required)
#   5  root                  apps/root.yaml, then wait wave by wave
#
# Safe to re-run: every step applies, none recreates. It prints NAMES, sync and
# health only - never Secret data (Secrets are verified by their key names).
#
# Usage
#   platform/bootstrap/cluster.sh                                   # current context, dev
#   platform/bootstrap/cluster.sh --rehearsal --context k3d-tryout  # NO real secrets
#   platform/bootstrap/cluster.sh --revision main --eso-source none
#
# --rehearsal      nothing real is read or written: no op, no az, no kv-qnsc-*.
#                  The CNPG CA is generated locally, and the Azure ClusterSecretStores
#                  are swapped for ESO's `fake` provider with dummy values, so the
#                  tunnel token is a dummy and cloudflared CANNOT connect. argotunnel
#                  name resolution is blackholed in CoreDNS as a second guard.
# --until-wave N   STOP WAITING after sync wave N (default 2). It does NOT stop
#                  ArgoCD: root's waves gate on health, so a later wave can be
#                  created while this script is still waiting. Later waves are held
#                  (switched to manual sync) as soon as they appear.
# --stop-after     after the last waited wave, make root manual and terminate its
#                  operation. Implied by --until-wave < 2.
# --eso-source     op (default) | none (credentials already seeded). With --rehearsal
#                  this is forced to none.
#   with op:       --op-vault <1Password vault> and, if they differ from the
#                  committed item ids, --eso-item-{platform,dev,prod} and
#                  --eso-client-id-{platform,dev,prod}. Items are resolved by ID:
#                  titles change, ids do not.
#
# Required tools: kubectl, helm, jq, az (the CNPG CA read; not with --rehearsal),
# op (only with --eso-source op). `yq` is NOT required.
set -euo pipefail
umask 077

ENV=dev
CONTEXT=""
VAULT_ADMIN=kv-qnsc-admin
CA_SECRET=""
PG_CLUSTER=""
REVISION=main
UNTIL_WAVE=2
WAVE_TIMEOUT=900
REFRESH_AFTER=90
MAX_REFRESH=2
ESO_SOURCE=op
REHEARSAL=0
OP_VAULT=""
# 1Password item ids, not titles: the titles were renamed once already (2026-10-31).
ESO_ITEM_PLATFORM=ht2edzbfxdbwc4jlvejcmg56we
ESO_ITEM_DEV=n3cpmxcojjck6xqcvcpvnvtxeq
ESO_ITEM_PROD=dk7ooe72yhdcliicppnbewotzy
ESO_CLIENT_ID_PLATFORM=""
ESO_CLIENT_ID_DEV=""
ESO_CLIENT_ID_PROD=""
STOP_AFTER=""

usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --context) CONTEXT=${2:?}; shift 2 ;;
    --env) ENV=${2:?}; shift 2 ;;
    --vault-admin) VAULT_ADMIN=${2:?}; shift 2 ;;
    --ca-secret) CA_SECRET=${2:?}; shift 2 ;;
    --pg-cluster) PG_CLUSTER=${2:?}; shift 2 ;;
    --revision) REVISION=${2:?}; shift 2 ;;
    --until-wave) UNTIL_WAVE=${2:?}; shift 2 ;;
    --wave-timeout) WAVE_TIMEOUT=${2:?}; shift 2 ;;
    --refresh-after) REFRESH_AFTER=${2:?}; shift 2 ;;
    --max-refresh) MAX_REFRESH=${2:?}; shift 2 ;;
    --eso-source) ESO_SOURCE=${2:?}; shift 2 ;;
    --rehearsal) REHEARSAL=1; shift ;;
    --op-vault) OP_VAULT=${2:?}; shift 2 ;;
    --eso-item-platform) ESO_ITEM_PLATFORM=${2:?}; shift 2 ;;
    --eso-item-dev) ESO_ITEM_DEV=${2:?}; shift 2 ;;
    --eso-item-prod) ESO_ITEM_PROD=${2:?}; shift 2 ;;
    --eso-client-id-platform) ESO_CLIENT_ID_PLATFORM=${2:?}; shift 2 ;;
    --eso-client-id-dev) ESO_CLIENT_ID_DEV=${2:?}; shift 2 ;;
    --eso-client-id-prod) ESO_CLIENT_ID_PROD=${2:?}; shift 2 ;;
    --stop-after) STOP_AFTER=1; shift ;;
    --keep-running) STOP_AFTER=0; shift ;;
    -h|--help) usage 0 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

case $ENV in
  dev) PG_CLUSTER=${PG_CLUSTER:-pg-dev} ;;
  prod) PG_CLUSTER=${PG_CLUSTER:-pg-rova} ;;
  *) echo "--env must be dev or prod, got: $ENV" >&2; exit 2 ;;
esac
CA_SECRET=${CA_SECRET:-platform-cnpg-ca-$ENV}
if [[ -z $STOP_AFTER ]]; then
  if (( UNTIL_WAVE < 2 )); then STOP_AFTER=1; else STOP_AFTER=0; fi
fi
if (( REHEARSAL )); then
  ESO_SOURCE=none
  OP_VAULT=""
fi

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$REPO_ROOT"

for c in kubectl helm jq; do
  command -v "$c" >/dev/null || { echo "missing required tool: $c" >&2; exit 1; }
done
case $ESO_SOURCE in
  op)
    command -v op >/dev/null || { echo "missing required tool: op (or pass --eso-source none)" >&2; exit 1; }
    [[ -n $OP_VAULT ]] || { echo "--op-vault is required with --eso-source op" >&2; exit 2; }
    ;;
  none) ;;
  *)    echo "--eso-source must be op or none" >&2; exit 2 ;;
esac

KUBECTL=(kubectl)
[[ -n $CONTEXT ]] && KUBECTL+=(--context "$CONTEXT")

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stuck" "$TMP/refreshes" "$TMP/held"

say() { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }

# ── versions.yaml: the argo-cd pin, without yq ───────────────────────────────
argo_cd_version() {
  local v
  v=$(awk '
    /^platform:/                { in_platform = 1; next }
    in_platform && /^[^ #]/     { in_platform = 0 }
    in_platform && /^  argo-cd:/ { found = 1; next }
    found && /^    version:/    { sub(/^[^:]*:[ \t]*/, ""); sub(/[ \t]*#.*$/, ""); gsub(/["'"'"']/, ""); print; exit }
  ' versions.yaml)
  if [[ ! $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "cannot read platform.argo-cd.version from versions.yaml (got '$v')" >&2
    exit 1
  fi
  printf '%s' "$v"
}

# ── Secret verification: key names only, never values ────────────────────────
secret_keys() {  # NAMESPACE NAME
  "${KUBECTL[@]}" -n "$1" get secret "$2" \
    -o go-template='{{range $k,$v := .data}}{{$k}} {{end}}' 2>/dev/null || true
}

expect_keys() {  # NAMESPACE NAME "k1 k2"
  local got k
  got=$(secret_keys "$1" "$2")
  [[ -n $got ]] || { echo "  ! secret $1/$2 is missing" >&2; return 1; }
  for k in $3; do
    [[ $got == *"$k"* ]] || { echo "  ! secret $1/$2 has no key '$k' (keys: $got)" >&2; return 1; }
  done
  say "  ok $1/$2 keys:$(echo "$got" | sed 's/ *$//;s/^/ /')"
}

# ══ 1. namespaces ═══════════════════════════════════════════════════════════
# external-secrets and argocd first: their LABELS must exist before the charts
# adopt them (Helm does not manage a pre-existing namespace's labels). onprem.yaml
# declares every remaining namespace and is idempotent.
step "namespaces"
"${KUBECTL[@]}" apply -f platform/namespaces/external-secrets.yaml -f platform/namespaces/argocd.yaml >/dev/null
"${KUBECTL[@]}" apply -f platform/namespaces/onprem.yaml >/dev/null
# `platform` is NOT here on purpose: platform-base creates it at wave -3, before
# anything that applies into it.
for ns in external-secrets argocd "data-$ENV"; do
  say "  ok namespace $ns ($("${KUBECTL[@]}" get ns "$ns" -o jsonpath='{.status.phase}'))"
done

# ══ 2. ESO service-principal credentials ════════════════════════════════════
# SEAM (agent F, workload identity): this is the ONLY thing that knows how ESO
# authenticates to the vaults. Replacing it changes nothing else in this script.
#
# Items are resolved by ID (titles change, ids do not) and the client id is an
# identifier passed at run time, so no site-specific value is committed.
eso_credentials() {
  local i store item cid name id file
  local -a stores=(platform dev) items=("$ESO_ITEM_PLATFORM" "$ESO_ITEM_DEV") cids=("$ESO_CLIENT_ID_PLATFORM" "$ESO_CLIENT_ID_DEV")
  if [[ $ENV == prod ]]; then
    stores=(platform prod)
    items=("$ESO_ITEM_PLATFORM" "$ESO_ITEM_PROD")
    cids=("$ESO_CLIENT_ID_PLATFORM" "$ESO_CLIENT_ID_PROD")
  fi
  for i in 0 1; do
    store=${stores[$i]} item=${items[$i]} cid=${cids[$i]}
    [[ -n $cid ]] || { echo "  ! --eso-client-id-$store is required with --eso-source op (the $store SP's Entra application id)" >&2; exit 1; }
    name="qnsc-eso-$store-cert"
    id=$item
    file=$(op item get "$id" --vault "$OP_VAULT" --format json | jq -r '.files[0].name')
    [[ -n $file && $file != null ]] || { echo "  ! 1Password item $id has no attached file" >&2; exit 1; }
    op read "op://$OP_VAULT/$id/$file" \
      | "${KUBECTL[@]}" -n external-secrets create secret generic "$name" \
          --from-file=tls.pem=/dev/stdin --from-literal=client-id="$cid" \
          --dry-run=client -o yaml \
      | "${KUBECTL[@]}" apply -f - >/dev/null
    expect_keys external-secrets "$name" "tls.pem client-id"
  done
}

step "ESO credentials (source: $ESO_SOURCE$([[ $REHEARSAL == 1 ]] && echo ', rehearsal'))"
if [[ $ESO_SOURCE == op ]]; then
  eso_credentials
else
  say "  skipped: qnsc-eso-*-cert must already exist"
  for s in platform dev; do
    if [[ -n $(secret_keys external-secrets "qnsc-eso-$s-cert") ]]; then
      expect_keys external-secrets "qnsc-eso-$s-cert" "tls.pem client-id"
    else
      say "  - external-secrets/qnsc-eso-$s-cert absent: the $s store stays NotReady"
    fi
  done
fi

# ══ 3. the static CNPG CA ═══════════════════════════════════════════════════
# ONE vault read (a second read of the same secret in one pipeline finds the
# pipe already consumed). The CA is ECDSA P-256 in SEC1 form; CNPG rejects
# anything else with "invalid private key PEM block type" (#68).
cnpg_ca() {
  local combined="$TMP/ca-combined" crt="$TMP/ca.crt" key="$TMP/ca.key"
  if (( REHEARSAL )); then
    # Never the vault, not even read-only: a throwaway CA of the same shape.
    say "  rehearsal: generating a throwaway CA (the vault is not read)"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 1 -noenc \
      -subj "/CN=rehearsal-cnpg-ca-$ENV" \
      -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
      -keyout "$TMP/ca.pk8" -out "$crt" 2>/dev/null
    openssl ec -in "$TMP/ca.pk8" -out "$key" 2>/dev/null
    rm -f "$TMP/ca.pk8"
  else
    command -v az >/dev/null || { echo "missing required tool: az" >&2; exit 1; }
    az keyvault secret show --vault-name "$VAULT_ADMIN" --name "$CA_SECRET" --query value -o tsv >"$combined"
    [[ -s $combined ]] || { echo "  ! $VAULT_ADMIN/$CA_SECRET is empty or unreadable" >&2; exit 1; }
    awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' "$combined" >"$crt"
    awk '/BEGIN EC PRIVATE KEY/,/END EC PRIVATE KEY/' "$combined" >"$key"
    rm -f "$combined"
  fi
  command -v openssl >/dev/null || { echo "missing required tool: openssl" >&2; exit 1; }
  [[ -s $crt && -s $key ]] \
    || { echo "  ! $CA_SECRET has no certificate or no 'EC PRIVATE KEY' block" >&2; exit 1; }
  # The PEM header is the check that matters: CNPG parses SEC1 only, and
  # `openssl ec` happily converts a PKCS#8 key, so it cannot be used as the guard.
  [[ $(head -1 "$key") == "-----BEGIN EC PRIVATE KEY-----" ]] \
    || { echo "  ! the CA key is not SEC1 ('BEGIN EC PRIVATE KEY'); CNPG cannot load it (#68)" >&2; exit 1; }

  "${KUBECTL[@]}" -n "data-$ENV" create secret generic "$PG_CLUSTER-ca" \
    --from-file=ca.crt="$crt" --from-file=ca.key="$key" \
    --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f - >/dev/null
  "${KUBECTL[@]}" -n "data-$ENV" create secret generic "$PG_CLUSTER-ca-pub" \
    --from-file=ca.crt="$crt" \
    --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f - >/dev/null
  rm -f "$key"
  expect_keys "data-$ENV" "$PG_CLUSTER-ca" "ca.crt ca.key"
  expect_keys "data-$ENV" "$PG_CLUSTER-ca-pub" "ca.crt"
}

step "CNPG CA ($ENV)"
cnpg_ca

# ══ 4. ArgoCD ═══════════════════════════════════════════════════════════════
# The last Helm install by hand. Version pinned in versions.yaml, not here.
step "ArgoCD"
ARGO_VERSION=$(argo_cd_version)
say "  version $ARGO_VERSION (versions.yaml)"
helm repo list 2>/dev/null | grep -q '^argo[[:space:]]' || helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
helm repo update argo >/dev/null
helm upgrade --install argocd argo/argo-cd -n argocd --version "$ARGO_VERSION" \
  -f platform/argocd/values.yaml --wait --timeout 10m >/dev/null
"${KUBECTL[@]}" -n argocd rollout status deploy/argocd-server --timeout=300s >/dev/null
say "  ok argocd $ARGO_VERSION: server rolled out"

# ══ rehearsal guards ════════════════════════════════════════════════════════
# A rehearsal cluster must not be able to act as production. Two independent
# guards, both only with --rehearsal:
#   - the stores are swapped for ESO's fake provider, with dummy values, so the
#     tunnel token is a dummy and cloudflared cannot connect
#   - argotunnel name resolution is blackholed in CoreDNS
block_argotunnel() {
  # k3s CoreDNS imports /etc/coredns/custom/*.override inside its server block,
  # which is where k3s expects customisations (the main Corefile is k3s's).
  # A separate server block, not an .override: the hosts plugin may appear only
  # once per server block, and the main one already has it.
  local body
  body='argotunnel.com:53 {
    template ANY ANY {
        rcode NXDOMAIN
    }
}
cfargotunnel.com:53 {
    template ANY ANY {
        rcode NXDOMAIN
    }
}'
  "${KUBECTL[@]}" -n kube-system create configmap coredns-custom \
    --from-literal=argotunnel.server="$body" --dry-run=client -o yaml \
    | "${KUBECTL[@]}" apply -f - >/dev/null
  "${KUBECTL[@]}" -n kube-system rollout restart deploy/coredns >/dev/null
  "${KUBECTL[@]}" -n kube-system rollout status deploy/coredns --timeout=120s >/dev/null
  say "  ok coredns: argotunnel.com and cfargotunnel.com answer NXDOMAIN"
}

# Values a fake store serves. Everything is the same dummy string except the one
# Key Vault secret whose real value is a JSON OBJECT (platform-grafana-alloy):
# `dataFrom.extract` JSON-unmarshals it, so a plain string fails there.
GRAFANA_JSON='{"GRAFANA_TOKEN":"rehearsal-dummy","GRAFANA_PROM_URL":"http://dummy.invalid","GRAFANA_PROM_USER":"dummy","GRAFANA_LOKI_URL":"http://dummy.invalid","GRAFANA_LOKI_USER":"dummy","GRAFANA_PYROSCOPE_URL":"http://dummy.invalid","GRAFANA_PYROSCOPE_USER":"dummy"}'

seed_fake_store() {  # STORE "KEY KEY ..."
  local store=$1 k v data=""
  set -- $2
  for k in "$@"; do
    case $k in
      platform-grafana-alloy) v=$GRAFANA_JSON ;;
      *)                      v=rehearsal-dummy ;;
    esac
    data="$data$(jq -cn --arg k "$k" --arg v "$v" '{key: $k, value: $v}'),"
  done
  "${KUBECTL[@]}" patch clustersecretstore "$store" --type json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/provider\",\"value\":{\"fake\":{\"data\":[${data%,}]}}}]" >/dev/null
}

store_keys() {  # STORE
  case $1 in
    platform) echo "platform-cloudflared-qnsc-apps platform-grafana-alloy platform-argocd-admin-bcrypt" ;;
    dev|prod)
      awk '/^secrets:/{s=1;next} s&&/^[^ #]/{s=0} s&&/^  *- name:/{print $NF}' \
        "values/rova/$1.secrets.yaml" 2>/dev/null ;;
  esac
}

# Hold an Application at manual sync, VERIFYING it took: a patch that silently
# failed is the difference between a rehearsal that stops and one that deploys
# the next wave.
hold_app() {  # NAME REASON
  local name=$1 reason=$2 pol
  pol=$("${KUBECTL[@]}" -n argocd get application "$name" -o jsonpath='{.spec.syncPolicy}' 2>/dev/null) || return 0
  [[ -z $pol ]] && return 0
  "${KUBECTL[@]}" -n argocd patch application "$name" --type merge \
    -p '{"spec":{"syncPolicy":null}}' >/dev/null 2>&1 || return 0
  if [[ -z $("${KUBECTL[@]}" -n argocd get application "$name" -o jsonpath='{.spec.syncPolicy}' 2>/dev/null) ]]; then
    say "  hold $name: $reason"
  fi
}

seed_rehearsal_stores() {
  [[ -e $TMP/stores-seeded ]] && return 0
  "${KUBECTL[@]}" get clustersecretstore kv-qnsc-platform >/dev/null 2>&1 || return 0
  # platform-eso has applied the Azure stores; hold it, then replace the provider.
  # The patch goes through ESO's validating webhook, which is not up the moment
  # the store object appears — a failed attempt is retried on the next poll.
  hold_app platform-eso "its stores are swapped for the fake provider"
  local s keys
  for s in platform "$ENV"; do
    keys=$(store_keys "$s")
    [[ -n $keys ]] || continue
    if ! seed_fake_store "kv-qnsc-$s" "$keys" 2>/dev/null; then
      say "  rehearsal: waiting for the ESO webhook before swapping kv-qnsc-$s"
      return 0
    fi
    say "  rehearsal: kv-qnsc-$s now serves $(echo "$keys" | wc -w | tr -d ' ') dummy values"
  done
  touch "$TMP/stores-seeded"
  # Anything already created against the Azure store re-reads it now.
  for ns in platform argocd "rova-$ENV"; do
    "${KUBECTL[@]}" -n "$ns" annotate externalsecret --all \
      force-sync="$(date +%s)" --overwrite >/dev/null 2>&1 || true
  done
}

held_names() { "${KUBECTL[@]}" -n argocd get applications -o json; }

# Any Application above the cutoff becomes manual as soon as it appears, so the
# stop point does not depend on ArgoCD's health timing. The tunnel deployment is
# scaled to zero if it ever starts.
guard_later_waves() {
  local name
  # root's own selfHeal would undo the child holds below. Hold it once the first
  # child exists (the in-flight operation keeps running either way).
  if [[ -n $("${KUBECTL[@]}" -n argocd get applications -o name 2>/dev/null \
             | grep -v 'application.argoproj.io/root$' | head -1) ]]; then
    hold_app root "selfHeal off, so the holds below stick"
  fi
  (( REHEARSAL )) && hold_app platform-eso "its stores are swapped for the fake provider"
  while read -r name; do
    [[ -e $TMP/held/$name ]] && continue
    hold_app "$name" "above wave $UNTIL_WAVE, switched to manual sync" || continue
    touch "$TMP/held/$name"
  done < <(held_names | jq -r --argjson cut "$UNTIL_WAVE" '
      .items[] | select(.metadata.name != "root")
      | .metadata.annotations["argocd.argoproj.io/sync-wave"] as $w
      | select($w == null or ($w | tonumber) > $cut)
      | .metadata.name' 2>/dev/null)

  if "${KUBECTL[@]}" -n platform get deploy cloudflared >/dev/null 2>&1; then
    local r
    r=$("${KUBECTL[@]}" -n platform get deploy cloudflared -o jsonpath='{.spec.replicas}')
    if [[ $r != 0 ]]; then
      "${KUBECTL[@]}" -n platform scale deploy/cloudflared --replicas=0 >/dev/null 2>&1 || true
      say "  hold cloudflared: scaled to 0 (a rehearsal never joins a tunnel)"
    fi
  fi
}

# ══ 5. hand over ════════════════════════════════════════════════════════════
# root is the ONE manifest applied by hand; everything else follows from git.
step "root (revision: $REVISION)"
if (( REHEARSAL )); then
  step "rehearsal guards"
  block_argotunnel
fi
sed "s|targetRevision: main|targetRevision: $REVISION|g" apps/root.yaml | "${KUBECTL[@]}" apply -f - >/dev/null
say "  ok application root applied"
guard_later_waves || true

apps_json() { "${KUBECTL[@]}" -n argocd get applications -o json; }

# Every app at wave $1: name<TAB>sync<TAB>health. ArgoCD treats a missing
# annotation as wave 0; `root` is excluded because it is the parent — its own
# operation stays Progressing until its LAST wave, so it can never satisfy an
# early one.
wave_rows() {
  # Only annotated Applications: the wave order exists because root applies ITS
  # resources in waves. Applications generated by the products ApplicationSet
  # carry no wave and are not part of root's operation.
  apps_json | jq -r --arg w "$1" '
    .items[]
    | select(.metadata.name != "root")
    | select(.metadata.annotations["argocd.argoproj.io/sync-wave"] != null)
    | select(.metadata.annotations["argocd.argoproj.io/sync-wave"] == $w)
    | [.metadata.name, (.status.sync.status // "Unknown"), (.status.health.status // "Unknown")]
    | @tsv'
}

# All of an app's resources report Healthy (or have no health check at all).
# This is the prometheus-crds case: CRDs sync, nothing reports Progressing, and
# ArgoCD never re-evaluates on its own.
resources_all_healthy() {
  "${KUBECTL[@]}" -n argocd get application "$1" -o json 2>/dev/null | jq -e '
    [ .status.resources[]? | select(.health != null) | .health.status ]
    | all(. == "Healthy" or . == "Suspended")' >/dev/null 2>&1
}

refresh_app() {
  local app=$1 count
  count=$(cat "$TMP/refreshes/$app" 2>/dev/null || echo 0)
  (( count < MAX_REFRESH )) || return 1
  count=$((count + 1))
  echo "$count" >"$TMP/refreshes/$app"
  "${KUBECTL[@]}" -n argocd annotate application "$app" \
    argocd.argoproj.io/refresh=normal --overwrite >/dev/null
  say "  refresh $app (stuck Progressing, all resources Healthy; attempt $count/$MAX_REFRESH)"
  date +%s >"$TMP/stuck/$app"
  return 0
}

wait_wave() {
  local wave=$1 deadline=$((SECONDS + WAVE_TIMEOUT))
  local rows name sync health bad now first sync_ok
  say "wave $wave: waiting (timeout ${WAVE_TIMEOUT}s)"
  while :; do
    if (( REHEARSAL )); then
      seed_rehearsal_stores || true
    fi
    guard_later_waves || true
    rows=$(wave_rows "$wave")
    if [[ -z $rows ]]; then
      (( SECONDS < deadline )) || { say "wave $wave: no Applications appeared in ${WAVE_TIMEOUT}s"; return 1; }
      sleep 5
      continue
    fi
    bad=0
    while IFS=$'\t' read -r name sync health; do
      # A rehearsal deliberately diverges from git (the stores are fake), so an
      # OutOfSync app that is Healthy counts: the divergence is the point.
      sync_ok=0
      [[ $sync == Synced ]] && sync_ok=1
      if (( REHEARSAL )) && [[ -e $TMP/stores-seeded && $sync == OutOfSync ]]; then sync_ok=1; fi
      if (( ! sync_ok )) || [[ $health != Healthy ]]; then
        bad=1
        if [[ $health == Progressing && $sync == Synced ]] && resources_all_healthy "$name"; then
          now=$(date +%s)
          first=$(cat "$TMP/stuck/$name" 2>/dev/null || echo "$now")
          [[ -e $TMP/stuck/$name ]] || echo "$now" >"$TMP/stuck/$name"
          if (( now - first >= REFRESH_AFTER )); then
            refresh_app "$name" || true
          fi
        else
          rm -f "$TMP/stuck/$name"
        fi
      fi
    done <<<"$rows"
    if (( bad == 0 )); then
      while IFS=$'\t' read -r name sync health; do
        say "  ok $name $sync/$health"
      done <<<"$rows"
      return 0
    fi
    if (( SECONDS >= deadline )); then
      say "wave $wave: TIMEOUT after ${WAVE_TIMEOUT}s"
      while IFS=$'\t' read -r name sync health; do
        say "  ! $name $sync/$health"
      done <<<"$rows"
      return 1
    fi
    sleep 10
  done
}

failed=0
for w in -3 -2 -1 0 1 2; do
  (( w <= UNTIL_WAVE )) || break
  wait_wave "$w" || { failed=1; break; }
done

# Stop the multi-wave operation so the waves we did not wait for are never
# created (a rehearsal must not deploy a second connector into a live tunnel).
if (( STOP_AFTER )) && (( failed == 0 )); then
  step "stop after wave $UNTIL_WAVE"
  "${KUBECTL[@]}" -n argocd patch application root --type merge -p '{"spec":{"syncPolicy":null}}' >/dev/null
  if command -v argocd >/dev/null && argocd --core -n argocd app terminate-op root >/dev/null 2>&1; then
    say "  ok root operation terminated; root is manual"
  else
    say "  ! could not terminate root's operation (argocd CLI missing or failed)."
    say "    Waves after $UNTIL_WAVE may still be created; the later-wave guard"
    say "    switches them to manual, but check before leaving this cluster."
  fi
fi

step "applications (names, sync, health only)"
apps_json | jq -r '.items[]
  | [(.metadata.annotations["argocd.argoproj.io/sync-wave"] // "-"), .metadata.name,
     (.status.sync.status // "Unknown"), (.status.health.status // "Unknown")]
  | @tsv' | sort -n | awk -F'\t' '{printf "  wave %2s  %-28s %-10s %s\n", $1, $2, $3, $4}'

if (( failed )); then
  echo
  echo "STOPPED: a wave did not reach Synced/Healthy. Fix the cause and re-run this script."
  exit 1
fi
say ""
say "bootstrap complete through wave $UNTIL_WAVE."
