#!/usr/bin/env bash
# Policy tests for platform/policy/*.yaml against a REAL API server (ValidatingAdmissionPolicy is
# evaluated by the apiserver, so a CEL typo only shows there).
#
#   scripts/test-policy.sh <kube-context>
#
# The context must be a THROWAWAY cluster (k3d). Needs the ExternalSecret CRD installed (the
# API server only calls the policy for a kind it knows): CI and the local recipe in
# platform/policy/README.md install just that CRD from the pinned ESO chart. Everything is
# `--dry-run=server`: nothing is stored, no operator runs.
#
# Each case says what it expects. A case that expects DENY must be refused WITH the policy's
# message (so a denial for another reason, e.g. a typo in the manifest, does not pass).
set -euo pipefail
cd "$(dirname "$0")/.."
CTX=${1:?usage: test-policy.sh <kube-context>}
case $CTX in k3d-*|kind-*) ;; *) echo "refusing: $CTX is not a k3d/kind context" >&2; exit 2 ;; esac
K=(kubectl --context "$CTX")

"${K[@]}" get crd externalsecrets.external-secrets.io >/dev/null

for ns in rova-dev opshub-dev; do
  "${K[@]}" create ns "$ns" --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null
  "${K[@]}" label ns "$ns" qnsc.vn/tenant=product qnsc.vn/env=dev --overwrite >/dev/null
done
"${K[@]}" apply -f platform/policy/admission.yaml -f platform/policy/bindings.yaml >/dev/null

es() { # es <name> <spec yaml, indented 2>  (namespace rova-dev)
  printf 'apiVersion: external-secrets.io/v1\nkind: ExternalSecret\nmetadata:\n  name: %s\n  namespace: %s\nspec:\n  secretStoreRef: { name: kv-qnsc-dev, kind: ClusterSecretStore }\n  target: { name: %s }\n%s\n' "$1" "${NS:-rova-dev}" "$1" "$2"
}

fail=0
# expect <ALLOW|DENY:<message fragment>> <label> <manifest>
expect() {
  local want=$1 label=$2 manifest=$3 out rc tries=0
  # a new policy needs a moment before the apiserver enforces it
  while :; do
    set +e; out=$(printf '%s' "$manifest" | "${K[@]}" apply --dry-run=server -f - 2>&1); rc=$?; set -e
    if [[ $want == ALLOW ]]; then
      [[ $rc == 0 ]] && { echo "  ok   allow  $label"; return; }
    else
      [[ $rc != 0 && $out == *"${want#DENY:}"* ]] && { echo "  ok   deny   $label"; return; }
    fi
    (( ++tries >= 8 )) && break
    sleep 1
  done
  echo "  FAIL ($want expected, rc=$rc)  $label"; echo "       $out" | head -3; fail=1
}

MSG_KEYS="may only read keys named"
MSG_FIND="dataFrom.find is forbidden"
MSG_SRC="sourceRef is forbidden"

echo "ExternalSecret scope (qnsc-externalsecret-scope)"
expect ALLOW "data key in own namespace"                "$(es good-data '  data:
    - { secretKey: A, remoteRef: { key: rova-dev-cookie-secret } }')"
expect ALLOW "chart shape: dataFrom.extract of <ns>-app" "$(es good-extract '  dataFrom:
    - extract: { key: rova-dev-app }')"
expect ALLOW "public CNPG CA mirror in data[]"          "$(es good-ca '  data:
    - { secretKey: ca.crt, remoteRef: { key: pg-dev-ca-pub, property: ca.crt } }')"
expect DENY:"$MSG_KEYS" "data key of another product"   "$(es bad-data '  data:
    - { secretKey: A, remoteRef: { key: opshub-dev-cookie-secret } }')"
expect DENY:"$MSG_KEYS" "dataFrom.extract of another product's bundle (G-01)" "$(es bad-extract '  dataFrom:
    - extract: { key: opshub-dev-app }')"
expect DENY:"$MSG_KEYS" "dataFrom.extract of a prefix lookalike (rova-devX)" "$(es bad-lookalike '  dataFrom:
    - extract: { key: rova-devious-app }')"
expect DENY:"$MSG_KEYS" "good data key must not hide a bad extract" "$(es bad-mixed '  data:
    - { secretKey: A, remoteRef: { key: rova-dev-cookie-secret } }
  dataFrom:
    - extract: { key: opshub-dev-app }')"
expect DENY:"$MSG_FIND" "dataFrom.find"                  "$(es bad-find '  dataFrom:
    - find: { name: { regexp: ".*" } }')"
expect DENY:"$MSG_SRC" "dataFrom.sourceRef (other store or generator)" "$(es bad-src-from '  dataFrom:
    - sourceRef: { storeRef: { name: kv-qnsc-prod, kind: ClusterSecretStore } }')"
expect DENY:"$MSG_SRC" "data[].sourceRef (other store)"  "$(es bad-src-data '  data:
    - secretKey: A
      remoteRef: { key: rova-dev-cookie-secret }
      sourceRef: { storeRef: { name: kv-qnsc-prod, kind: ClusterSecretStore } }')"

# Regression guard: every ExternalSecret the chart renders today must still be admitted in its own
# namespace, so tightening the policy can never silently break a product sync.
echo "rendered ExternalSecrets are admitted (every product/env row enabled in appsets/products.yaml)"
# Only DEPLOYED rows: a values file that exists without a row (opshub/prod is the EKS-era shape,
# with dataFrom.find) is not synced anywhere and is not this guard's business.
while read -r product env; do
  f="rendered/$product/$env.yaml"; ns="$product-$env"
  [[ -f $f ]] || { echo "  FAIL $f missing for an enabled row"; fail=1; continue; }
  "${K[@]}" create ns "$ns" --dry-run=client -o yaml | "${K[@]}" apply -f - >/dev/null
  "${K[@]}" label ns "$ns" qnsc.vn/tenant=product "qnsc.vn/env=$env" --overwrite >/dev/null
  docs=$(python3 - "$f" "$ns" <<'PY'
import sys, yaml
f, ns = sys.argv[1:3]
out = []
for d in yaml.safe_load_all(open(f)):
    if d and d.get("kind") == "ExternalSecret":
        d["metadata"]["namespace"] = ns
        out.append(d)
print(yaml.safe_dump_all(out), end="")
PY
  )
  n=$(printf '%s' "$docs" | grep -c '^kind: ExternalSecret' || true)
  [[ $n -gt 0 ]] || continue
  set +e; out=$(printf '%s' "$docs" | "${K[@]}" apply --dry-run=server -f - 2>&1); rc=$?; set -e
  if [[ $rc == 0 ]]; then echo "  ok   $ns ($n ExternalSecrets)"; else echo "  FAIL $ns"; echo "$out" | grep -v memcache | head -3; fail=1; fi
done < <(grep -E '^[[:space:]]*-[[:space:]]*\{[^}]*product:[^}]*env:' appsets/products.yaml \
          | sed -E 's/.*product:[[:space:]]*([a-z0-9-]+),[[:space:]]*env:[[:space:]]*([a-z]+).*/\1 \2/')

(( fail == 0 )) && echo "policy tests: PASS" || { echo "policy tests: FAIL"; exit 1; }
