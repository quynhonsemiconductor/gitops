# Rehearsal — bootstrap from zero, in a cluster that cannot act as production

The point of `cluster.sh` is that a new site is a command, not a memory. This page
records what that command actually did on a cluster with nothing in it, so the
next person knows what is proven and what is not.

## Method

```
platform/bootstrap/cluster.sh --rehearsal --context k3d-<name> \
  --env dev --revision <branch> --until-wave 0 --stop-after
```

`--rehearsal` means no `op`, no `az`, no `kv-qnsc-*` (see
`platform/argocd/bootstrap.md`). The CNPG CA is generated and thrown away, the
Azure `ClusterSecretStore`s are swapped for ESO's `fake` provider with dummy
values, `argotunnel.com`/`cfargotunnel.com` answer NXDOMAIN, and every wave above
the cutoff is held at manual sync.

Cluster: `k3d` v5.9.0, k3s v1.35.5, one server, macOS arm64. Nothing else ran on
the machine.

## Stubs, exactly

| Stubbed | Instead of | Consequence |
|---|---|---|
| Key Vault reads | `az keyvault secret show` | the CNPG CA is a throwaway 1-day ECDSA P-256 CA; every secret is `rehearsal-dummy` |
| ESO service-principal certs | 1Password items + Entra client ids | the stores are `provider.fake`, not Azure |
| tunnelled traffic | the `qnsc-apps` connector | cloudflared is held and scaled to 0; its DNS is blackholed |
| products (wave 1) | rova-dev with real R2/Entra | held at manual sync; never started |
| Grafana credentials | the real Alloy JSON | a JSON object of dummies, so `dataFrom.extract` still unmarshals |

Not stubbed: namespaces and their labels, the CNPG CA object shape (ECDSA P-256,
SEC1 header), the ArgoCD version pin, the wave order, every Application's
sync/health, the `pg-dev` cluster and its managed roles, Valkey, cert-manager, the
CNPG operator, the admission policies, and the `root` app-of-apps.

## Result — final run (2026-10-31)

| | |
|---|---|
| Command | `cluster.sh --rehearsal --env dev --until-wave 0 --stop-after` |
| Wall time | **4 min 13 s** (`real 4:12.84`), from an empty k3d cluster |
| Manual interventions | **none** |
| Exit | 0 — "bootstrap complete through wave 0" |
| Waves | -3, -2, -1, 0 all Synced + Healthy |
| cloudflared | never started: ReplicaSet desired 0, **no pod ever ran**, token was a dummy anyway |
| Re-run (twice, and once after drift) | passes; the second run changes nothing — see below |

Wave state at the end:

```
wave -3  platform-base                Synced     Healthy
wave -3  platform-prometheus-crds     Synced     Healthy
wave -2  platform-cert-manager        Synced     Healthy
wave -2  platform-eso                 OutOfSync  Healthy   (fake stores: deliberate)
wave -1  platform-cnpg                Synced     Healthy
wave -1  platform-secrets             Synced     Healthy
wave  0  platform-data                OutOfSync  Healthy   (rehearsal tolerance)
wave  -  root                         OutOfSync  Healthy
wave  2  platform-cloudflared         OutOfSync  Healthy   (held; 0 replicas)
wave  -  rova-dev                     OutOfSync  Missing   (held, never synced)
```

Two `OutOfSync` entries are the rehearsal's own divergence: `platform-eso`'s
stores are fake, and `platform-data` carries CNPG/Valkey field drift that the
real clusters reconcile on their own schedule. The waits accept OutOfSync +
Healthy in `--rehearsal` for exactly this reason.

## What the rehearsal found

Every one of these was a real defect in the scripts, found before they were used
anywhere.

1. **The wave wait counted `root` as a child.** It is the parent; its operation
   stays Progressing until its own last wave, so it can never satisfy wave 0.
2. **Products polluted the wave-0 wait.** The products ApplicationSet generates
   Applications with no `sync-wave`; treating "missing" as wave 0 pulled
   `rova-dev` (health Missing) into the wait. Only annotated Applications are
   root's children.
3. **`--until-wave` did not stop ArgoCD.** A rehearsal cluster created
   `platform-cloudflared` 48 s *after* the script returned. Root's wave order is
   one operation; the fix is to guard until that operation reports a terminal
   phase, not to claim it was terminated.
4. **A patch that silently failed.** `root` was left automated because the
   hold patch's error was swallowed; every hold is now read back and retried.
5. **Store seeding raced the ESO webhook.** The provider swap was rejected while
   the webhook had no endpoints and never retried.
6. **`dataFrom.extract` needs JSON.** A plain dummy string fails
   `unable to unmarshal secret: invalid character 'r'`, so the Grafana value is
   a JSON object of dummies.
7. **A second `hosts` directive crashloops CoreDNS** ("this plugin can only be
   used once per Server Block"); the tunnel blackhole is a separate `.server`
   block.
8. **A title is not an identifier.** Resolving 1Password items by title broke on
   item titles containing spaces (and the titles had already been renamed once).

## Re-run: bootstrap, bootstrap again, then once after drift

A second run must change nothing; a run after drift must restore exactly the
drifted object. Measured on the same rehearsal cluster, all three runs exit 0.

| Run | Action | Wall time | Result |
|---|---|---|---|
| A | from an empty k3d cluster | **4 min 15 s** | waves -3..0 Synced/Healthy |
| B | `cluster.sh` again, unchanged cluster | **7 s** | snapshot before == after |
| C | delete `data-dev/pg-dev-ca-pub`, then run | **7 s** | snapshot == post-B, mirror restored byte-identical |

The snapshot compares, across `platform`, `argocd`, `external-secrets` and
`data-dev`: every Secret's data hash, every Application's `generation` and spec
hash, the Helm release revision, and the `argocd-server` Deployment generation.
Run B changed none of them; run C changed only `pg-dev-ca-pub`, whose `ca.crt`
now hashes exactly as before the deletion.

What made a re-run a mutation before this (each fixed at the cause):

1. **The CNPG CA was regenerated every run** and replaced `pg-dev-ca` under a
   running `pg-dev` — observed: fingerprint `B4:21..` → `38:B7..`. The CA is now
   created once; `--force pg-dev-ca` is the only way to replace it, and a drifted
   `-pub` mirror is rebuilt FROM the CA that is already there and compared byte
   for byte.
2. **ESO credential Secrets were re-read and re-applied** every run. They are kept
   when both keys are present, unless `--force qnsc-eso-<store>-cert`.
3. **ArgoCD was `helm upgrade`d regardless of version.** Now the release is named
   and left alone when it is already at the `versions.yaml` pin.
4. **Every ExternalSecret was force-synced** even when the stores were already
   fake, rewriting three Secrets. Seeding now only touches a store that is not
   already `provider.fake`.
5. **root was re-applied** (automated) and then held again. A rehearsal leaves an
   existing root exactly as the cluster has it.

A `--revision` that ArgoCD cannot fetch now fails in ~45 s with the comparison
error, instead of spending a wave timeout on "no Applications appeared".

### The `Unknown` health that started this

The original failure (`platform-data` health `Unknown` on a re-run) did **not**
reproduce on a fresh cluster with the same code — the same re-run passed in 27 s.
What was reproduced is the CA replacement above, which is the plausible trigger:
CNPG reissues server certificates when the CA changes under it. The wait now does
what the prometheus-crds case needed — a bounded refresh for `Unknown` whose every
resource reports healthy, then a note and it stops holding the wave — and the
mutation that could cause it no longer happens.

## Not proven by this rehearsal

- The real ESO stores authenticating to Azure, and the real CNPG CA read (both
  need credentials; both are one code path, exercised only by the k3s-01 run).
- Waves 1 and 2 (products, cloudflared) — deliberately held.
- `secrets.sh` against Azure: only `--check` and the CA generation were run
  locally; every vault write is owner-run.
- Retention of the tunnel-token path: the dummy proves cloudflared fails closed,
  not that a real token connects.
