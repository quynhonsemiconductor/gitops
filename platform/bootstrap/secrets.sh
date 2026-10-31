#!/usr/bin/env bash
# Create the Key Vault inputs the on-prem bootstrap reads (platform/argocd/bootstrap.md).
#
# The OWNER runs this, from anywhere, with an Azure login that can write the vaults.
# The SA runs platform/bootstrap/cluster.sh afterwards.
#
# Rules this script keeps:
#   - every value reaches Key Vault through stdin; nothing is printed but NAMES
#   - nothing is written to disk except short-lived Key Vault fetches of this script's
#     own temporary files (mode 600, removed on exit)
#   - idempotent: an existing secret is SKIPPED, never overwritten. `--force NAME`
#     (repeatable) replaces exactly that one.
#   - it GENERATES everything this estate can generate, and ASKS only for what a
#     vendor or the owner must supply:
#       generated  DB role passwords, app cookie/csrf/better-auth secrets,
#                  the ArgoCD admin password + its bcrypt hash, the CNPG CA
#       asked      Entra client secret, R2 key pair, tunnel token, admin roster,
#                  Grafana Alloy credentials
#
# Names and formats are the ones values/rova/<env>.secrets.yaml records; this script
# checks itself against that file (see `drift_check`) so the two cannot drift.
#
# Usage
#   platform/bootstrap/secrets.sh                      # dev, kv-qnsc-dev
#   platform/bootstrap/secrets.sh --env prod --vault-app kv-qnsc-prod
#   platform/bootstrap/secrets.sh --force rova-dev-db-app
#   platform/bootstrap/secrets.sh --skip-site          # app secrets only (a second site
#                                                      # rejoining an existing platform)
#   platform/bootstrap/secrets.sh --check              # verify tooling + name drift only
#
# Required tools: az (logged in), openssl, htpasswd (bcrypt), python3.
set -euo pipefail
umask 077

ENV=dev
PRODUCT=rova
VAULT_APP=""
VAULT_PLATFORM=kv-qnsc-platform
VAULT_ADMIN=kv-qnsc-admin
SITE=qnsc
DO_SITE=1
CHECK_ONLY=0
FORCE=()

usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --env) ENV=${2:?--env needs dev or prod}; shift 2 ;;
    --product) PRODUCT=${2:?}; shift 2 ;;
    --vault-app) VAULT_APP=${2:?}; shift 2 ;;
    --vault-platform) VAULT_PLATFORM=${2:?}; shift 2 ;;
    --vault-admin) VAULT_ADMIN=${2:?}; shift 2 ;;
    --site) SITE=${2:?}; shift 2 ;;
    --skip-site) DO_SITE=0; shift ;;
    --force) FORCE+=("${2:?--force needs a secret name}"); shift 2 ;;
    --check) CHECK_ONLY=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

case $ENV in
  dev|prod) ;;
  *) echo "--env must be dev or prod, got: $ENV" >&2; exit 2 ;;
esac
VAULT_APP=${VAULT_APP:-kv-qnsc-$ENV}

for c in az openssl htpasswd python3; do
  command -v "$c" >/dev/null || { echo "missing required tool: $c" >&2; exit 1; }
done

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ── expiry dates ────────────────────────────────────────────────────────────
# macOS (BSD) date first; GNU date second. Both print RFC3339 UTC.
expires_days() {
  local d=$1
  if date -u -v+1d +%Y-%m-%d >/dev/null 2>&1; then
    date -u -v+"${d}"d +%Y-%m-%dT%H:%M:%SZ
  else
    date -u -d "+${d} days" +%Y-%m-%dT%H:%M:%SZ
  fi
}
EXP_6M=$(expires_days 182)
EXP_1Y=$(expires_days 365)
EXP_10Y=$(expires_days 3650)

is_forced() {
  local n
  for n in ${FORCE[@]+"${FORCE[@]}"}; do [[ $n == "$1" ]] && return 0; done
  return 1
}

exists() {
  az keyvault secret show --vault-name "$1" --name "$2" --query id -o tsv >/dev/null 2>&1
}

# put VAULT NAME EXPIRES TAGS... — value on stdin. Prints the name, never the value.
put() {
  local v=$1 n=$2 e=$3
  shift 3
  if exists "$v" "$n" && ! is_forced "$n"; then
    echo "  = $v/$n exists, skipped"
    cat >/dev/null
    return 0
  fi
  az keyvault secret set --vault-name "$v" --name "$n" --file /dev/stdin --encoding utf-8 \
    --expires "$e" --tags owner=platform created-by=bootstrap-secrets "$@" -o none
  echo "  + $v/$n"
}

# ask VAULT NAME EXPIRES PROMPT — reads the value hidden, from the terminal.
ask() {
  local v=$1 n=$2 e=$3 p=$4 val
  if exists "$v" "$n" && ! is_forced "$n"; then
    echo "  = $v/$n exists, skipped"
    return 0
  fi
  printf '  %s: ' "$p" >&2
  read -rs val
  printf '\n' >&2
  if [[ -z ${val:-} ]]; then
    echo "  - $n left empty: skipped (nothing depending on it will sync until it exists)"
    return 0
  fi
  printf '%s' "$val" | put "$v" "$n" "$e"
  unset val
}

# ── drift check: every name in values/<product>/<env>.secrets.yaml is handled ──
# The values file is the source of truth for WHICH Key Vault secrets a product reads.
# A secret added there without a rule here would silently never exist.
drift_check() {
  local f="values/$PRODUCT/$ENV.secrets.yaml"
  [[ -f $f ]] || { echo "  (no $f: name check skipped)"; return 0; }
  local handled=" " p="$PRODUCT-$ENV"
  handled+="$p-cookie-secret $p-csrf-secret $p-better-auth-secret "
  handled+="$p-platform-admin-emails $p-entra-client-secret "
  handled+="$p-storage-access-key-id $p-storage-secret-access-key "
  handled+="$p-db-app $p-db-worker $p-db-migrator "
  # graph-cert is a Key Vault CERTIFICATE (identity lane), named here so the check
  # knows it is deliberately not a plain secret.
  handled+="$p-graph-cert "
  local missing=0 n
  while read -r n; do
    [[ $handled == *" $n "* ]] || { echo "  ! $f names $n, which this script does not create" >&2; missing=1; }
  done < <(awk '/^secrets:/{s=1;next} s&&/^[^ #]/{s=0} s&&/^  *- name:/{print $NF}' "$f")
  (( missing == 0 )) || { echo "add a rule for the names above before running" >&2; exit 1; }
}

echo "== env=$ENV product=$PRODUCT vault-app=$VAULT_APP vault-platform=$VAULT_PLATFORM vault-admin=$VAULT_ADMIN site=$SITE"
drift_check
if (( CHECK_ONLY )); then
  echo "== --check: names this run would create (nothing written)"
  p="$PRODUCT-$ENV"
  for n in "$p-db-app" "$p-db-worker" "$p-db-migrator" "$p-cookie-secret" "$p-csrf-secret" \
           "$p-better-auth-secret" "$p-entra-client-secret" "$p-storage-access-key-id" \
           "$p-storage-secret-access-key" "$p-platform-admin-emails"; do
    echo "  $VAULT_APP/$n"
  done
  if (( DO_SITE )); then
    echo "  $VAULT_ADMIN/admin-argocd-password"
    echo "  $VAULT_PLATFORM/platform-argocd-admin-bcrypt"
    echo "  $VAULT_PLATFORM/platform-cloudflared-$SITE-apps"
    echo "  $VAULT_PLATFORM/platform-grafana-alloy"
  fi
  echo "  $VAULT_ADMIN/platform-cnpg-ca-$ENV"
  exit 0
fi
echo "== Azure: $(az account show --query user.name -o tsv 2>/dev/null) / $(az account show --query name -o tsv 2>/dev/null)"

# ── generated: DB role passwords (CNPG managed roles + chart) ────────────────
echo "== $VAULT_APP: $PRODUCT-$ENV DB role passwords (hex 48)"
for r in app worker migrator; do
  openssl rand -hex 24 | tr -d '\n' | put "$VAULT_APP" "$PRODUCT-$ENV-db-$r" "$EXP_1Y" "role=$PRODUCT-$r"
done

# ── generated: app signing secrets ───────────────────────────────────────────
# distinct values per role: rotating one must not sign out the other.
echo "== $VAULT_APP: $PRODUCT-$ENV generated app secrets"
openssl rand -hex 32 | tr -d '\n' | put "$VAULT_APP" "$PRODUCT-$ENV-cookie-secret" "$EXP_1Y"
openssl rand -hex 32 | tr -d '\n' | put "$VAULT_APP" "$PRODUCT-$ENV-csrf-secret" "$EXP_1Y"
openssl rand -base64 48 | tr -d '\n' | put "$VAULT_APP" "$PRODUCT-$ENV-better-auth-secret" "$EXP_1Y"

# ── asked: third-party and owner-provided values ─────────────────────────────
echo "== $VAULT_APP: $PRODUCT-$ENV values issued elsewhere (input hidden; Enter skips)"
ask "$VAULT_APP" "$PRODUCT-$ENV-entra-client-secret" "$EXP_6M" \
  "Entra '$PRODUCT $ENV' app client secret value (6 months)"
ask "$VAULT_APP" "$PRODUCT-$ENV-storage-access-key-id" "$EXP_1Y" \
  'R2 API token Access Key ID (attachments + public-assets, object read/write)'
ask "$VAULT_APP" "$PRODUCT-$ENV-storage-secret-access-key" "$EXP_1Y" \
  'R2 API token Secret Access Key'
ask "$VAULT_APP" "$PRODUCT-$ENV-platform-admin-emails" "$EXP_1Y" \
  'PLATFORM_ADMIN_EMAILS (comma-separated, no spaces; staff roster stays out of the public repo)'

if (( DO_SITE )); then
  # ── generated + asked: the platform's own credentials ─────────────────────
  echo "== ArgoCD admin: plaintext -> $VAULT_ADMIN, bcrypt -> $VAULT_PLATFORM"
  if exists "$VAULT_ADMIN" admin-argocd-password && ! is_forced admin-argocd-password; then
    echo "  = $VAULT_ADMIN/admin-argocd-password exists, skipped (hash left as is)"
  else
    openssl rand -base64 48 | tr -d '/+=\n' | cut -c1-40 >"$TMP/argo"
    put "$VAULT_ADMIN" admin-argocd-password "$EXP_1Y" <"$TMP/argo"
    # htpasswd -i reads the password from stdin; ArgoCD accepts the $2a$ prefix only.
    # The hash always follows a NEW password, so it is rewritten with it.
    htpasswd -niBC 10 "" <"$TMP/argo" | tr -d ':\n' | sed 's/^\$2y\$/$2a$/' \
      | az keyvault secret set --vault-name "$VAULT_PLATFORM" --name platform-argocd-admin-bcrypt \
          --file /dev/stdin --encoding utf-8 --expires "$EXP_1Y" \
          --tags owner=platform created-by=bootstrap-secrets -o none
    echo "  + $VAULT_PLATFORM/platform-argocd-admin-bcrypt"
  fi

  echo "== $SITE tunnel token -> $VAULT_PLATFORM/platform-cloudflared-$SITE-apps"
  if exists "$VAULT_PLATFORM" "platform-cloudflared-$SITE-apps" && ! is_forced "platform-cloudflared-$SITE-apps"; then
    echo "  = exists, skipped"
  else
    printf '  Paste the %s-apps tunnel token (input hidden, Enter): ' "$SITE" >&2
    read -rs tok
    printf '\n' >&2
    [[ ${tok:-} == eyJ* ]] || { echo "  token does not start with eyJ - aborting" >&2; exit 1; }
    printf '%s' "$tok" | put "$VAULT_PLATFORM" "platform-cloudflared-$SITE-apps" "$EXP_1Y"
    unset tok
  fi

  echo "== Grafana Alloy JSON -> $VAULT_PLATFORM/platform-grafana-alloy (Enter on every prompt = empty placeholder)"
  if exists "$VAULT_PLATFORM" platform-grafana-alloy && ! is_forced platform-grafana-alloy; then
    echo "  = exists, skipped"
  else
    # two parallel arrays, not an associative one: macOS ships bash 3.2
    G_KEYS=(GRAFANA_PROM_URL GRAFANA_PROM_USER GRAFANA_LOKI_URL GRAFANA_LOKI_USER
            GRAFANA_PYROSCOPE_URL GRAFANA_PYROSCOPE_USER GRAFANA_TOKEN)
    G_VALS=()
    placeholder=false
    for k in "${G_KEYS[@]}"; do
      if [[ $k == GRAFANA_TOKEN ]]; then
        printf '  %s (input hidden): ' "$k" >&2
        read -rs v
      else
        printf '  %s: ' "$k" >&2
        read -r v
      fi
      printf '\n' >&2
      G_VALS+=("$v")
    done
    [[ -z ${G_VALS[6]:-} ]] && placeholder=true
    for i in 0 1 2 3 4 5 6; do printf '%s\0%s\0' "${G_KEYS[$i]}" "${G_VALS[$i]}"; done \
      | python3 -I -c 'import sys,json; p=sys.stdin.buffer.read().split(b"\0")[:-1]; print(json.dumps({p[i].decode():p[i+1].decode() for i in range(0,len(p),2)},sort_keys=True),end="")' \
      | put "$VAULT_PLATFORM" platform-grafana-alloy "$EXP_1Y" "placeholder=$placeholder"
    unset G_KEYS G_VALS v
  fi
fi

# ── generated: the CNPG CA, one per env, 10 years ────────────────────────────
# CNPG loads ONLY an ECDSA key in SEC1 form ("EC PRIVATE KEY", pkg/certs
# ParseECPrivateKey); RSA or PKCS#8 fails with "invalid private key PEM block type"
# (#68). The key is unencrypted because CNPG cannot load an encrypted one.
echo "== CNPG CA ($ENV, 10 years) -> $VAULT_ADMIN/platform-cnpg-ca-$ENV"
if exists "$VAULT_ADMIN" "platform-cnpg-ca-$ENV" && ! is_forced "platform-cnpg-ca-$ENV"; then
  echo "  = exists, skipped"
else
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 3650 -noenc \
    -subj "/CN=$SITE-cnpg-ca-$ENV" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -keyout "$TMP/ca.pk8" -out "$TMP/ca.crt" 2>/dev/null
  openssl ec -in "$TMP/ca.pk8" -out "$TMP/ca.key" 2>/dev/null
  openssl ec -in "$TMP/ca.key" -noout 2>/dev/null \
    || { echo "generated key is not SEC1 EC - aborting" >&2; exit 1; }
  cat "$TMP/ca.crt" "$TMP/ca.key" | put "$VAULT_ADMIN" "platform-cnpg-ca-$ENV" "$EXP_10Y" \
    "rotate-by=$(expires_days 3285 | cut -c1-10)"
fi

echo
echo "== Done. Names only:"
for v in "$VAULT_PLATFORM" "$VAULT_APP" "$VAULT_ADMIN"; do
  echo "  $v: $(az keyvault secret list --vault-name "$v" --query '[].name' -o tsv | tr '\n' ' ')"
done
cat <<EOF

Not done here, by design:
  $PRODUCT-$ENV-graph-cert   a Key Vault CERTIFICATE (az keyvault certificate create, auto-renew),
                             registered in infra live/identity - identity lane, not a plain secret.
  ESO service-principal material  comes from 1Password at bootstrap (cluster.sh), never from here.
EOF
