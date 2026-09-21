#!/usr/bin/env bash
# Apply the platform layer to one cluster, in the order platform/README.md sets out.
#
#     ./scripts/bootstrap-cluster.sh dev
#     ./scripts/bootstrap-cluster.sh prod
#
# ── WHY THIS EXISTS ─────────────────────────────────────────────────────────
#
# platform/README.md is the specification and it is correct. What it cannot do is
# substitute the `qnsc-ENV-*` placeholders, and there are five of them across four
# files. A placeholder left in place fails at RUNTIME, not at apply:
#
#   compute/nodeclass.yaml   role: qnsc-ENV-node          no node ever launches
#   compute/nodeclass.yaml   kubernetes.io/cluster/qnsc-ENV   selector matches nothing
#   eso/values.yaml          qnsc-ENV-external-secrets    secrets never sync
#   keda/values.yaml         qnsc-ENV-keda                scalers never authenticate
#   secrets/cluster-info.yaml  name: qnsc-ENV             Loki labels say "ENV"
#
# Every one of those is a green apply followed by something that quietly does not
# work — the failure shape this estate keeps finding. So substitution belongs in a
# script, not in a human's sed.
#
# ── WHAT IT VERIFIES, AND WHY THAT MATTERS MORE THAN WHAT IT APPLIES ────────
#
# Step 1 does not just apply the node pools, it WAITS FOR A NODE and checks its
# architecture and capacity type. That check is the whole reason platform/compute
# exists: Auto Mode's built-in `general-purpose` pool is amd64-only and
# on-demand-only, every workload here asks for arm64, and most ask for spot — so
# before this directory existed the cluster could not schedule ArgoCD, let alone a
# product. A bootstrap that "succeeded" without a node proves nothing.
#
# Idempotent: every step is `kubectl apply` or `helm upgrade --install`, so a
# re-run after a failure resumes rather than duplicating.
set -euo pipefail

ENV="${1:-}"
case "$ENV" in
  dev|prod) ;;
  *) echo "usage: $0 <dev|prod>" >&2; exit 2 ;;
esac

CLUSTER="qnsc-${ENV}"
CTX="${KUBE_CONTEXT:-$CLUSTER}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

say()  { printf '\n\033[1m── %s\033[0m\n' "$*"; }
ok()   { printf '   \033[32mok\033[0m  %s\n' "$*"; }
die()  { printf '\n   \033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }

# ── 0. preconditions ────────────────────────────────────────────────────────
say "0. preconditions"
command -v kubectl >/dev/null || die "kubectl not installed"
command -v helm    >/dev/null || die "helm not installed"
kubectl --context "$CTX" --request-timeout=20s get --raw /readyz >/dev/null 2>&1 \
  || die "cannot reach $CLUSTER's API server as this identity.

  Two separate causes, and they need different fixes:
    * TIMEOUT  — the endpoint is private. Open the keyhole:
                   cd infra/live/cluster-$ENV
                   tofu apply -var 'public_access_cidrs=[\"\$(curl -s https://checkip.amazonaws.com)/32\"]'
                 and close it again with a bare 'tofu apply' when you are done.
    * Unauthorized — this identity has no EKS access entry. On PROD that is by
                 design (§10b: no standing admin), so assume qnsc-prod-breakglass."
ok "$CLUSTER reachable"

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
ok "account $ACCOUNT"

# Copied to a temp tree first, so the repository is never mutated and a half-run
# cannot leave a substituted file staged by accident.
# ── substitution ────────────────────────────────────────────────────────────
# Only the directories THIS SCRIPT APPLIES (steps 1-4). eso/, keda/, alloy/,
# argocd/, clamd/ and secrets/ are later steps with their own prerequisites, and
# substituting them here would mean silently rewriting files nobody is about to
# apply — then having to guess what "correct" looks like for values this script
# does not own (clamd's replica count differs per environment, for one).
#
# THERE ARE THREE PLACEHOLDER SHAPES, not one, which is how two of them were
# missed on the first attempt:
#
#   -ENV      qnsc-ENV-node · qnsc-platform-ENV · kubernetes.io/cluster/qnsc-ENV
#   /ENV/     qnsc/ENV/platform/grafana  — a Secrets Manager PATH (in secrets/)
#   env: ENV  a label value               — (in clamd/)
#
# `qnsc-platform-ENV` does not contain the substring `qnsc-ENV`, so an earlier
# `s/qnsc-ENV/qnsc-dev/` left it alone — and the guard, which looked for the same
# literal, agreed nothing had survived. The NodeClass then applied cleanly and
# reported `SubnetsNotFound: SubnetSelector did not match any Subnets`: a runtime
# failure two steps from its cause. Found 2026-09-21.
APPLY_DIRS=(compute namespaces policy eso keda)

cp -R "$ROOT/platform" "$WORK/platform"
for d in "${APPLY_DIRS[@]}"; do
  find "$WORK/platform/$d" -name '*.yaml' -print0 \
    | xargs -0 perl -pi -e "s{-ENV\\b}{-${ENV}}g; s{/ENV/}{/${ENV}/}g; s{(env:\\s*)ENV\\b}{\\1${ENV}}g"
done

# The guard reads the BARE TOKEN and ignores comments, because a comment that says
# "ENV = dev | prod" is documentation and a manifest value that still says ENV is a
# bug. The earlier version searched for the same literal the substitution used, so
# it could only confirm that the substitution had done what it had just done — a
# guard sharing an assumption with the thing it checks is not a guard.
survivors=""
for d in "${APPLY_DIRS[@]}"; do
  while IFS= read -r -d '' f; do
    if sed 's/#.*//' "$f" | grep -qE '\bENV\b'; then
      survivors="${survivors}\n  ${f#"$WORK"}: $(sed 's/#.*//' "$f" | grep -nE '\bENV\b' | head -2 | tr '\n' ' ')"
    fi
  done < <(find "$WORK/platform/$d" -name '*.yaml' -print0)
done
[ -z "$survivors" ] || die "an ENV placeholder survived substitution:$(printf '%b' "$survivors")"
ok "placeholders substituted for ENV=$ENV"

# ── 1. compute — BEFORE EVERYTHING, including ArgoCD ────────────────────────
say "1. compute — the NodeClass and NodePools (§2)"
kubectl --context "$CTX" apply -f "$WORK/platform/compute/nodeclass.yaml"
kubectl --context "$CTX" apply -f "$WORK/platform/compute/nodepools.yaml"
ok "applied"

# A NodeClass whose selectors match nothing is accepted by the API and then never
# launches anything, so check the status the controller writes rather than trusting
# the apply.
for _ in $(seq 1 30); do
  ready=$(kubectl --context "$CTX" get nodeclass qnsc -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  [ "$ready" = "True" ] && break
  sleep 4
done
[ "${ready:-}" = "True" ] || die "NodeClass qnsc is not Ready after 2 minutes.
  Almost always a selector matching nothing. Check both:
    aws ec2 describe-subnets --filters Name=tag:Tier,Values=cluster Name=tag:Network,Values=qnsc-platform-$ENV
    aws ec2 describe-security-groups --filters Name=tag:kubernetes.io/cluster/$CLUSTER,Values=owned
  Then: kubectl --context $CTX describe nodeclass qnsc"
ok "NodeClass qnsc is Ready"

# ── 2. namespaces ───────────────────────────────────────────────────────────
say "2. namespaces — the labels three mechanisms select on"
kubectl --context "$CTX" apply -f "$WORK/platform/namespaces/"
ok "applied"

# ── 3. THE PROOF: can this cluster schedule what the estate renders? ────────
say "3. proving a node launches for arm64 + spot"
cat >"$WORK/probe.yaml" <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: schedulability-probe
  namespace: platform
spec:
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/arch: arm64
    karpenter.sh/capacity-type: spot
  terminationGracePeriodSeconds: 0
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    seccompProfile: { type: RuntimeDefault }
  containers:
    - name: probe
      image: public.ecr.aws/docker/library/busybox:1.37
      command: ["sh", "-c", "echo scheduled on $(uname -m); sleep 2"]
      resources:
        requests: { cpu: 10m, memory: 16Mi }
        limits:  { memory: 16Mi }
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: { drop: ["ALL"] }
YAML
kubectl --context "$CTX" delete pod schedulability-probe -n platform --ignore-not-found >/dev/null 2>&1
kubectl --context "$CTX" apply -f "$WORK/probe.yaml" >/dev/null
echo "   waiting for Karpenter to provision an arm64 spot node (up to 5 min)..."
if kubectl --context "$CTX" wait --for=condition=Ready pod/schedulability-probe -n platform --timeout=300s >/dev/null 2>&1 \
   || kubectl --context "$CTX" get pod schedulability-probe -n platform -o jsonpath='{.status.phase}' 2>/dev/null | grep -qE 'Succeeded|Running'; then
  node=$(kubectl --context "$CTX" get pod schedulability-probe -n platform -o jsonpath='{.spec.nodeName}')
  arch=$(kubectl --context "$CTX" get node "$node" -o jsonpath='{.metadata.labels.kubernetes\.io/arch}')
  cap=$(kubectl --context "$CTX" get node "$node" -o jsonpath='{.metadata.labels.karpenter\.sh/capacity-type}')
  ok "scheduled on $node  arch=$arch  capacity=$cap"
  [ "$arch" = "arm64" ] || die "expected arm64, got $arch"
else
  kubectl --context "$CTX" describe pod schedulability-probe -n platform | tail -20
  die "NOTHING SCHEDULED. This is the blocker platform/compute exists to fix:
  Auto Mode's built-in general-purpose pool is amd64-only and on-demand-only, and
  every workload in this estate asks for arm64, most for spot. If this fails after
  compute/ applied cleanly, the NodePools are present but cannot satisfy the
  selectors — compare gitops/platform/compute/nodepools.yaml against the pod above."
fi
kubectl --context "$CTX" delete pod schedulability-probe -n platform --ignore-not-found >/dev/null 2>&1

# ── 4. policy — admission BEFORE the operators it will judge ────────────────
say "4. policy — ValidatingAdmissionPolicy, then its bindings"
kubectl --context "$CTX" apply -f "$WORK/platform/policy/admission.yaml"
kubectl --context "$CTX" apply -f "$WORK/platform/policy/bindings.yaml"
ok "applied — a policy with no binding enforces nothing, hence the order"

# ── 5. operators with no external credential ───────────────────────────────
# ESO and KEDA go in here because their only prerequisite is an IRSA role that
# `infra/live/cluster-<env>` already created. alloy/, gateway/ and cloudflared/ are
# deliberately NOT here: each needs a credential value that lives outside this
# repository (a Grafana Cloud push token, a Cloudflare tunnel token), and a script
# that half-installs them leaves a chart in a failed state nobody asked for.
say "5. External Secrets Operator and KEDA"

ver() { python3 -c "import yaml,sys; print(yaml.safe_load(open('$ROOT/versions.yaml'))['platform']['$1']['$2'])"; }

for comp in external-secrets keda; do
  case "$comp" in
    external-secrets) ns=external-secrets; vals="$WORK/platform/eso/values.yaml" ;;
    keda)             ns=platform;         vals="$WORK/platform/keda/values.yaml" ;;
  esac
  repo="$(ver "$comp" repo)"; chart="$(ver "$comp" chart)"; version="$(ver "$comp" version)"
  echo "   $comp $version from $repo"
  helm repo add "$comp" "$repo" >/dev/null 2>&1 || true
  helm repo update "$comp" >/dev/null 2>&1 || true
  helm --kube-context "$CTX" upgrade --install "$comp" "$comp/$chart" \
    --version "$version" --namespace "$ns" --create-namespace \
    -f "$vals" --wait --timeout 8m >/dev/null \
    || die "$comp failed to install. helm --kube-context $CTX -n $ns status $comp"
  ok "$comp installed in $ns"
done

# An operator whose pods are Running but whose IRSA role is unusable looks healthy
# and silently never syncs a secret, so check the annotation resolved to a real role
# rather than to the literal placeholder.
for sa_ns in external-secrets:external-secrets platform:keda-operator; do
  ns="${sa_ns%%:*}"; sa="${sa_ns##*:}"
  arn=$(kubectl --context "$CTX" get sa "$sa" -n "$ns" \
        -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || true)
  case "$arn" in
    *ENV*) die "$ns/$sa still carries an ENV placeholder in its IRSA annotation: $arn" ;;
    arn:aws:iam::*) ok "$ns/$sa -> $arn" ;;
    *)     printf '   \033[33mwarn\033[0m %s/%s has no IRSA annotation (%s)\n' "$ns" "$sa" "${arn:-none}" ;;
  esac
done

say "Done — steps 0-5 of platform/README.md"
cat <<EOF
  This cluster can now schedule what the estate renders, which it could not before.

  Still to do, and each needs something this script deliberately does not assume:
    alloy/          the Grafana Cloud push credential
    gateway/ cloudflared/   the Cloudflare tunnel token
    argocd/         PROD ONLY, and prod has no standing admin — assume
                    qnsc-prod-breakglass (§10b)
    clamd/          after alloy, so the freshclam metric has a collector

  And close the keyhole when you are finished:
    cd infra/live/cluster-${ENV} && tofu apply
EOF
