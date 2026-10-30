# Bootstrap — who installs the installer

ONPREM-PLAN §14. Git holds everything except a few hand-made things: ArgoCD itself, the
`root` Application, the ESO service-principal Secrets and the static CNPG CA. Every
platform component (ESO, cert-manager, CNPG + barman plugin, Valkey, cloudflared, the
admission policies, the namespaces) is an Application under `../../apps/platform-*.yaml`,
ordered by sync wave (§11.2) and managed by `root`.

Never put a secret value in argv or Git. Every secret below goes in through stdin.

## Before you start (Key Vault, owner)

Names and shapes the Applications read. Create each with
`... | az keyvault secret set --vault-name <vault> --name <name> --file /dev/stdin --expires <date> --tags owner=<who> rotate-by=<date> -o none`
and verify by name only.

| Vault | Secret | Shape | Read by |
|---|---|---|---|
| `kv-qnsc-platform` | `platform-cloudflared-qnsc-apps` | plain string (tunnel token) | `platform/secrets` -> `cloudflared` |
| `kv-qnsc-platform` | `platform-grafana-alloy` | JSON with the seven `GRAFANA_*` keys | `platform/secrets` -> `grafana-cloud` |
| `kv-qnsc-platform` | `platform-argocd-admin-bcrypt` | plain string (bcrypt hash) | `platform/argocd/externalsecret.yaml` |
| `kv-qnsc-dev` | `rova-dev-app` | JSON bundle | chart `rova-app` |
| `kv-qnsc-dev` | `rova-dev-db-app`, `rova-dev-db-migrator`, `rova-dev-db-worker` | plain-string passwords | the CNPG managed roles AND the chart |
| `kv-qnsc-dev` | `rova-dev-graph-cert` | one combined PEM (key + cert) | chart worker volume `cert.pem` |

ArgoCD admin hash (from the plaintext kept in `kv-qnsc-admin`; stdin end to end):

```bash
az keyvault secret show --vault-name kv-qnsc-admin --name <argocd-admin-password-secret> --query value -o tsv \
  | tr -d '\n' | htpasswd -niBC 10 x | cut -d: -f2 | sed 's/^\$2y/$2a/' | tr -d '\n' \
  | az keyvault secret set --vault-name kv-qnsc-platform --name platform-argocd-admin-bcrypt \
      --file /dev/stdin --expires <date> --tags owner=platform rotate-by=<date> -o none
```

## Steps (SA, in order, after review)

```bash
export KUBECONFIG=~/.kube/onprem.yaml     # over WARP

# 1. The two namespaces the Secrets below live in (labels first, so Helm adopts argocd).
kubectl apply -f platform/namespaces/external-secrets.yaml -f platform/namespaces/argocd.yaml

# 2. ESO service-principal Secrets, one per store, from kv-qnsc-admin through stdin.
#    Keys are what stores-onprem.yaml reads: tls.pem (combined PEM) and client-id
#    (the SP application id, an identifier, not a secret). platform + dev are enough for
#    rova-dev; prod joins with the prod move.
for e in platform dev; do
  az keyvault secret show --vault-name kv-qnsc-admin --name platform-eso-$e-cert --query value -o tsv \
    | kubectl -n external-secrets create secret generic qnsc-eso-$e-cert \
        --from-file=tls.pem=/dev/stdin --from-literal=client-id=<QNSC ESO ${e} application id>
done

# 3. The static pg-dev CA (platform/cnpg/ca.md, data-dev): pg-dev-ca (crt+key) and
#    pg-dev-ca-pub (crt only). The data-dev namespace must exist first:
kubectl apply -f platform/namespaces/onprem.yaml   # idempotent; declares every namespace
#    ...then the two `kubectl create secret` commands of platform/cnpg/ca.md.

# 4. ArgoCD (the last Helm install by hand; version from versions.yaml)
helm repo add argo https://argoproj.github.io/argo-helm && helm repo update
helm install argocd argo/argo-cd -n argocd --version "$(yq '.platform.argo-cd.version' versions.yaml)" \
  -f platform/argocd/values.yaml
kubectl -n argocd rollout status deploy/argocd-server

# 5. Hand over.
kubectl apply -f apps/root.yaml
kubectl -n argocd get applications -w     # wave -3 -> 2; names and health only
```

The repo is public, so ArgoCD needs no repository credential.

## What root does, in wave order

```
-3  platform-base            namespaces (labels), admission policies + bindings, data-prod NetworkPolicy
-3  platform-prometheus-crds monitoring CRDs (every product chart renders a PrometheusRule)
-3  products (AppProject)
-2  platform-eso             operator in `external-secrets` + the ClusterSecretStores
-2  platform-cert-manager
-1  platform-secrets         grafana-cloud, cloudflared, argocd admin hash (kv-qnsc-platform)
-1  platform-cnpg            operator + barman plugin in `cnpg-system`
 0  platform-data            valkey-dev, valkey-kb-dev, Postgres ImageCatalogs
 1  products (ApplicationSet) rova-dev, opshub-dev, kb-dev
 2  platform-cloudflared     traffic arrives last
```

`platform-base`, `platform-prometheus-crds` and `platform-data` have `prune: false`
(a pruned Namespace or PVC deletes data). A failed wave holds the next one:
`platform-secrets` stays Degraded until the stores from step 2 are Valid, and that is the
signal, not a bug. The CNPG `Cluster` for dev is not part of this wave list yet (PLT-B7).

## Not in git yet

| Missing | Tracked as |
|---|---|
| CNPG Clusters, managed roles, ObjectStore, backups, PriorityClasses, ResourceQuotas | PLT-B7 |
| k8s-monitoring / OTLP receiver (replaces the host-side Alloy values here) | PLT-H2 |
| Prod Applications and values | PLT-B2 |
| `ghcr-pull` imagePullSecret (`platform-<env>-ghcr-pull`, ONPREM-PLAN §7.1) | not started; needed if a product image is private |
