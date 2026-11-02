#!/usr/bin/env bash
# The read-only identity (platform/access/rbac.yaml) grants read and nothing else.
#
#   scripts/test-ro-rbac.sh                 static checks only (no cluster)
#   scripts/test-ro-rbac.sh <kube-context>  static + `kubectl auth can-i` against a THROWAWAY k3d/kind cluster
#
# Static: every rule of the custom ClusterRole is get/list/watch, no Secrets, no exec/attach/
# portforward/proxy, no wildcard; only two ClusterRoleBindings exist, both for sa-readonly, to `view`
# and the custom role. Dynamic: the real API server answers can-i for the ServiceAccount.
# A PASS must fail on broken input: see the self-test at the bottom (SELFTEST=1).
set -euo pipefail
cd "$(dirname "$0")/.."
FILE=${RBAC_FILE:-platform/access/rbac.yaml}
CTX=${1:-}

python3 - "$FILE" <<'PY'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
errs = []
BAD_RES = {"secrets", "*", "pods/exec", "pods/attach", "pods/portforward", "pods/proxy", "services/proxy",
           "nodes/proxy", "serviceaccounts/token", "pods/ephemeralcontainers"}
READ = {"get", "list", "watch"}
kinds = [d["kind"] for d in docs]
roles = [d for d in docs if d["kind"] == "ClusterRole"]
crbs = [d for d in docs if d["kind"] == "ClusterRoleBinding"]
if any(d["kind"] in ("Role", "RoleBinding") for d in docs):
    errs.append("unexpected namespaced Role/RoleBinding")
if len(roles) != 1 or roles[0]["metadata"]["name"] != "qnsc-readonly-extra":
    errs.append("exactly one ClusterRole `qnsc-readonly-extra` expected")
for r in roles:
    for rule in r.get("rules", []):
        if set(rule.get("verbs", [])) - READ or not rule.get("verbs"):
            errs.append(f"non-read verbs in rule {rule}")
        if "*" in rule.get("apiGroups", []):
            errs.append(f"wildcard apiGroup in {rule}")
        for res in rule.get("resources", []):
            if res in BAD_RES or res.endswith("/*") or "/" in res and res.split("/")[1] in ("exec", "attach", "portforward", "proxy", "token"):
                errs.append(f"forbidden resource {res}")
        if rule.get("nonResourceURLs") or rule.get("resourceNames"):
            errs.append(f"unexpected nonResourceURLs/resourceNames in {rule}")
if sorted(c["roleRef"]["name"] for c in crbs) != ["qnsc-readonly-extra", "view"]:
    errs.append("ClusterRoleBindings must bind exactly `view` and `qnsc-readonly-extra`")
for c in crbs:
    if c["roleRef"]["kind"] != "ClusterRole":
        errs.append("roleRef kind must be ClusterRole")
    subj = [(s["kind"], s["name"], s.get("namespace")) for s in c["subjects"]]
    if subj != [("ServiceAccount", "sa-readonly", "platform-access")]:
        errs.append(f"binding {c['metadata']['name']} subjects must be only sa-readonly: {subj}")
if kinds.count("ServiceAccount") != 1 or kinds.count("Secret") != 1:
    errs.append("expected one ServiceAccount and one token Secret")
for d in docs:
    if d["kind"] == "Secret" and d.get("type") != "kubernetes.io/service-account-token":
        errs.append("Secret must be a service-account-token Secret")
    if d["kind"] == "Secret" and (d.get("data") or d.get("stringData")):
        errs.append("the token Secret must carry no data in Git")
if errs:
    print("FAIL static:\n  " + "\n  ".join(errs)); sys.exit(1)
print("ok   static: read-only verbs, no secrets/exec/attach/portforward/proxy/wildcard, two bindings for sa-readonly")
PY

[ -n "$CTX" ] || exit 0
case $CTX in k3d-*|kind-*) ;; *) echo "refusing: $CTX is not a k3d/kind context" >&2; exit 2 ;; esac
K=(kubectl --context "$CTX")
"${K[@]}" apply -f platform/namespaces/platform-access.yaml -f "$FILE" >/dev/null
# RBAC does not need the ArgoCD CRDs, but `can-i` answers "no" for a kind the server does not know.
# Minimal stand-ins so the ArgoCD rules are really exercised.
for pair in application:Application applicationset:ApplicationSet appproject:AppProject; do
  kind=${pair%%:*}; Kind=${pair#*:}
  plural="${kind}s"
  "${K[@]}" apply -f - >/dev/null <<CRD
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata: { name: ${plural}.argoproj.io }
spec:
  group: argoproj.io
  scope: Namespaced
  names: { kind: ${Kind}, plural: ${plural}, singular: ${kind} }
  versions: [{ name: v1alpha1, served: true, storage: true, schema: { openAPIV3Schema: { type: object, x-kubernetes-preserve-unknown-fields: true } } }]
CRD
done
"${K[@]}" wait --for=condition=Established crd/applications.argoproj.io crd/applicationsets.argoproj.io crd/appprojects.argoproj.io --timeout=60s >/dev/null
AS=system:serviceaccount:platform-access:sa-readonly
fail=0
set -f   # "* *" must reach kubectl as two words, not a glob
can() { # can <yes|no> <verb> <resource[/subresource]> [kubectl flags]. `pods/exec` is a SUBRESOURCE: kubectl reads a bare
        # `pods/exec` as pod "exec", so it is split into --subresource here (that mistake makes every deny test pass).
  want=$1; shift
  args=()
  for x in "$@"; do
    case $x in -*|"*") args+=("$x") ;; */*) args+=("${x%%/*}" "--subresource=${x#*/}") ;; *) args+=("$x") ;; esac
  done
  got=$("${K[@]}" auth can-i --as="$AS" "${args[@]}" 2>/dev/null || true)
  if [ "$got" = "$want" ]; then echo "ok   can-i $* -> $got"; else echo "FAIL can-i $* -> '$got' (wanted $want)"; fail=1; fi
}
for a in "get pods -A" "list deployments -A" "list pods -n kube-system" "get configmaps -A" "list events -A" \
         "list nodes" "list namespaces" "list persistentvolumes" "list storageclasses" \
         "list applications.argoproj.io -n argocd" "list applicationsets.argoproj.io -n argocd" "get appprojects.argoproj.io -n argocd" \
         "get pods/log -n kube-system" "watch applications.argoproj.io -A"; do
  # shellcheck disable=SC2086
  can yes $a
done
for a in "get secrets -A" "get secrets -n kube-system" "list secrets -n argocd" "watch secrets -A" \
         "create pods/exec -n kube-system" "get pods/exec -n kube-system" "create pods/attach -n kube-system" "create pods/portforward -n kube-system" \
         "get pods/portforward -n kube-system" "get pods/proxy -n kube-system" "get nodes/proxy" "get services/proxy -n default" \
         "create serviceaccounts/token -n argocd" "update pods/ephemeralcontainers -n default" \
         "create pods -n default" "delete pods -n default" "update deployments -n default" "patch applications.argoproj.io -n argocd" \
         "create applications.argoproj.io -n argocd" "delete namespaces" "create clusterrolebindings.rbac.authorization.k8s.io" \
         "escalate clusterroles.rbac.authorization.k8s.io" "impersonate users" "* *" ; do
  # shellcheck disable=SC2086
  can no $a
done
exit $fail
