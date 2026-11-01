# Bootstrap — who installs the installer

ONPREM-PLAN §14. Git holds everything except the handful of things a cluster cannot
create for itself: its namespaces' labels, the ESO service-principal Secrets, the
static CNPG CA, ArgoCD, and the `root` Application. Everything after `root` — the
platform operators, the databases, the products — is Applications in `apps/` and
`appsets/`, ordered by sync wave (§11.2).

Two scripts do all of it. They are the runbook; this page is the why and the map.

```bash
# 1. the owner, once per site (or per env): creates the Key Vault inputs
platform/bootstrap/secrets.sh --env dev

# 2. the SA, on the cluster: steps 1-5, then waits wave by wave
platform/bootstrap/cluster.sh --env dev
```

Both are idempotent and safe to re-run. Both print NAMES, sync and health only —
never Secret data. Secrets are verified by their key names (`go-template` over
`.data`), not by reading them.

## secrets.sh — what it generates and what it asks

Generated here, because this estate can generate it:

```
DB role passwords          <product>-<env>-db-{app,worker,migrator}   hex 48
app secrets                -cookie-secret, -csrf-secret (hex 64), -better-auth-secret (base64 64)
ArgoCD admin               password in <admin vault>, bcrypt hash in <platform vault>
CNPG CA                    platform-cnpg-ca-<env>: ECDSA P-256, SEC1, 10 years
```

Asked for, because only a vendor or the owner has it:

```
Entra client secret        the sign-in app's VALUE, <= 6 months
R2 key pair                access key id + secret access key
PLATFORM_ADMIN_EMAILS      a staff roster; therefore never in this public repo
tunnel token               platform-cloudflared-<site>-apps
Grafana Alloy              the seven values the Alloy env reads (Enter = empty placeholder)
```

Vault names and env are flags, so a second site or prod is an argument, not an edit:

```bash
--env dev|prod  --product rova  --vault-app kv-qnsc-dev --vault-platform kv-qnsc-platform
--vault-admin kv-qnsc-admin --site qnsc --skip-site --force NAME --check
```

`--check` verifies the tooling and checks this script against
`values/<product>/<env>.secrets.yaml`, which stays the source of truth for WHICH
Key Vault secrets a product reads. A secret added there without a rule here fails
the check instead of silently never existing.

The one name this script deliberately does not create is `<product>-<env>-graph-cert`:
it is a Key Vault CERTIFICATE (`az keyvault certificate create`, auto-renew), owned
by the identity lane, not a plain secret.

## cluster.sh — steps 1-5, then the waves

```
1  namespaces           platform/namespaces/{external-secrets,argocd,onprem}.yaml
                        labels first: Helm adopts a pre-existing namespace and never
                        fixes its labels
2  ESO credentials      one function (eso_credentials) reads each SP's combined PEM
                        from 1Password BY ITEM ID (titles change; ids do not) and
                        pairs it with the client id passed in. THE SEAM for agent F's
                        workload identity: replacing that one function is the whole
                        change.
3  CNPG CA              ONE `az keyvault secret show` -> ca.crt + the SEC1
                        `EC PRIVATE KEY` block -> pg-<env>-ca and pg-<env>-ca-pub.
                        A PKCS#8 or RSA key is refused here, with the reason (#68)
4  ArgoCD               helm upgrade --install, version from versions.yaml.
                        No yq: one awk reads `platform.argo-cd.version`
5  root                 apps/project*.yaml first (root belongs to `platform`,
                        and an Application whose project does not exist is refused),
                        then apps/root.yaml with --revision substituted
```

Then it waits wave by wave. A wave is done when every Application in it is
`Synced` + `Healthy`. Two behaviours worth knowing:

- **stuck Progressing, resources all Healthy** is the `platform-prometheus-crds`
  case: the Application synced, nothing reports unhealthy, and ArgoCD never
  re-evaluates. The script refreshes such an app — at most twice, 90 s apart, and
  only when every resource that has a health check reports `Healthy`.
- **`--until-wave N`** stops the *waiting* after wave N; it cannot stop ArgoCD.
  Root's wave order lives inside one sync operation, which runs to completion
  whether or not root itself is automated — the rehearsal proved that by creating
  `platform-cloudflared` 48 s after the script had returned. So `--stop-after`
  (implied below wave 2) does not claim to stop it: it **guards** until root
  reports a terminal phase — every Application above the cutoff is switched to
  manual sync as it appears, `root`'s selfHeal is off so those holds stick, and
  `cloudflared` is scaled to zero — then prints what exists.

Flags: `--context`, `--env`, `--revision`, `--until-wave`, `--wave-timeout`,
`--eso-source op|none`, `--rehearsal`, `--stop-after`, `--keep-running`,
`--force NAME`, `--vault-admin`, `--ca-secret`, `--pg-cluster`, `--op-vault`,
`--eso-item-*`, `--eso-client-id-*`.

## Re-running it on a cluster that already exists

The next real use is a re-run: k3s-01, after the ESO workload-identity change.
So every step is a no-op when its target is already there.

```
namespaces        kubectl apply — same object, no change
ESO credentials   kept when both keys exist; --force qnsc-eso-<store>-cert replaces
CNPG CA           created ONCE. A re-run never regenerates it, and a missing
                  -ca-pub mirror is rebuilt FROM the CA that is already there,
                  then compared byte for byte. --force pg-dev-ca replaces it
ArgoCD            installed or upgraded ONLY when the pinned version differs
root              applied; a rehearsal leaves an existing root as the cluster has it
```

Why the CA matters: in a rehearsal the CA is generated, so regenerating it would
swap the CA under a running `pg-dev` (observed: the fingerprint changed and CNPG
reissued certificates). The measured re-run result is in `bootstrap/REHEARSAL.md`.

## `--rehearsal`: a cluster that cannot act as production

A rehearsal must prove the mechanics without holding real credentials:

```
no op, no az, no kv-qnsc-*        the CNPG CA is generated and thrown away
ESO fake provider                 the Azure ClusterSecretStores are patched to
                                  provider.fake with dummy values, so the tunnel
                                  token is a dummy and cloudflared cannot connect.
                                  The Grafana value is a JSON object of dummies,
                                  because `dataFrom.extract` unmarshals it.
CoreDNS                           region1/2.v2.argotunnel.com resolve to 0.0.0.0
later waves                       held (manual sync), cloudflared scaled to 0
```

What a rehearsal therefore does NOT prove: that the real ESO stores authenticate,
that the real CNPG CA is readable, and anything a product does with real
credentials. Wave 0 (the platform's data plane) is fully exercised.

```bash
k3d cluster create qnsc-rehearsal --wait
platform/bootstrap/cluster.sh --rehearsal --context k3d-qnsc-rehearsal \
  --revision <branch> --until-wave 0 --stop-after
```

## Before you start: the Key Vault items

Key Vault secrets are created through stdin and verified by name. The names and
their formats are `values/<product>/<env>.secrets.yaml`; the vaults are:

| Where | What | Written by |
|---|---|---|
| `kv-qnsc-dev` | one secret per rova-dev value (cookie/csrf/better-auth, entra, R2 pair, admin roster, db-app/worker/migrator) | `secrets.sh` |
| `kv-qnsc-platform` | `platform-cloudflared-<site>-apps`, `platform-grafana-alloy` (JSON, keys ARE Alloy's env names), `platform-argocd-admin-bcrypt` | `secrets.sh` |
| `kv-qnsc-admin` | `platform-cnpg-ca-<env>` (crt + SEC1 key), `admin-argocd-password` | `secrets.sh` |
| 1Password | `eso-{platform,dev,prod}-combined-pem` Document items | identity lane |

`cluster.sh` reads those items by ID (the titles were renamed once already) and
takes the SP client id as a flag (`--eso-client-id-<store>`); `--eso-item-<store>`
overrides the id for another site. Rotate the ESO certificates if their material
has ever been printed — the 2026-10-31 incident is why.

## What root does, in wave order

```
-3  platform-base            namespaces (labels), admission policies + bindings, data-prod NetworkPolicy
-3  platform-prometheus-crds monitoring CRDs (every product chart renders a PrometheusRule)
-3  products (AppProject)
-2  platform-eso             operator in `external-secrets` + the ClusterSecretStores
-2  platform-cert-manager
-1  platform-secrets         grafana-cloud, cloudflared, argocd admin hash (kv-qnsc-platform)
-1  platform-cnpg            operator + barman plugin in `cnpg-system`
 0  platform-data            valkey-dev, valkey-kb-dev, Postgres ImageCatalogs, pg-dev (+ rova managed roles)
 1  products (ApplicationSet) rova-dev, opshub-dev, kb-dev
 2  platform-cloudflared     traffic arrives last
 3  platform-data-prod       valkey-rova, pg-rova (+ role timeouts); last, so an unready kv-qnsc-prod cannot hold earlier waves
```

`platform-base`, `platform-prometheus-crds` and `platform-data` have `prune: false`
(a pruned Namespace or PVC deletes data). A failed wave holds the next one:
`platform-secrets` stays Degraded until the ESO stores are Valid, and that is the
signal, not a bug. `pg-dev` needs the hand-applied `pg-dev-ca` secret (step 3) and
the three `rova-dev-db-*` Key Vault secrets before wave 0. `pg-rova` (wave 3) needs `data-prod/pg-rova-ca`
(`cluster.sh --env prod`, or ca.md by hand) and the four `rova-prod-db-*` secrets in `kv-qnsc-prod`
(`secrets.sh --env prod`) plus the `qnsc-eso-prod-cert` Secret, or the kv-qnsc-prod store stays InvalidProviderConfig.

## Not in git yet

| Missing | Tracked as |
|---|---|
| opshub/kb roles in `pg-dev`, ObjectStore/backups, dump CronJobs, restore test, PriorityClasses, ResourceQuotas | PLT-B7 |
| k8s-monitoring / OTLP receiver (replaces the host-side Alloy values here) | PLT-H2 |
| Prod Applications and values | PLT-B2 |
| `ghcr-pull` imagePullSecret (`platform-<env>-ghcr-pull`, ONPREM-PLAN §7.1) | not started; needed if a product image is private |
| ESO workload identity (replaces the 1Password SP path) | agent F |

## From zero

The first real bootstrap (k3s-01, 2026-10-31) ran this by hand and found three
defects, each fixed at its cause rather than in the runbook: the CNPG CA had to be
ECDSA SEC1 (#68), an image pin named a tag that did not exist (#69), and
`platform-prometheus-crds` needed one refresh (now automatic in `cluster.sh`).

The rehearsal record — cluster, wall time, stubs, manual interventions — is in
`platform/bootstrap/REHEARSAL.md`.
