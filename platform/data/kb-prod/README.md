# kb production, prepared and NOT enabled

Born in the argocd-audit M2 layout: ONE directory per data scope, ONE Application for it, the
restore test inside the same directory. Nothing here is synced: root reads `apps/*.yaml` only, and
`apps/platform-data-kb-prod.yaml` (moved from `application.yaml.disabled`, 2026-11-05) is the switch. kb prod is a FRESH launch (kb never had a prod
environment): no data move, so the cluster starts empty and the connectors ingest after the
cutover.

| File | What |
|---|---|
| `pg-kb.yaml` | CNPG cluster `pg-kb` in data-prod (one instance, 500m/2Gi, 20+8 Gi on `local-path-retain`), managed roles kb_app / kb_migrator (owner, NOCREATEROLE) / kb_readonly (dump: `pg_read_all_data` + BYPASSRLS, gitops#305), the `kb` Database with pgvector + pgcrypto, passwords from kv-qnsc-prod, kb_app role timeouts (30/60 s) |
| `pg-kb-backup.yaml` | barman-cloud ObjectStore -> `s3://qnsc-backups/pg-kb/`, WAL archiving (serverName `pg-kb-g1`), nightly base backup 19:30 UTC |
| `pg-kb-dump.yaml` | own ExternalSecret `pg-kb-dump-r2` (kv-qnsc-prod `r2-dump-rw-*`, no dependency on the rova app) + nightly `pg_dump -Fc` as kb_readonly (never the owner) -> `dumps/daily|weekly|monthly/pg-kb-<date>.dump`, write-once, 21:00 UTC |
| `valkey-kb.yaml` | dedicated prod Celery broker: `noeviction` + AOF on a 2 Gi PVC, ACL (user `kb`, derived from ONE kv secret) |
| `restore-test-kb.yaml` | weekly restore test (CronJob in `restore-test`, Sundays 20:00 UTC, REQUIRE_DATA=1; passed the 2026-11-06 G1 run), including the kb_app grant proof from qnsc-kb-backend#364 and the kb_readonly BYPASSRLS check |
| `apps/platform-data-kb-prod.yaml` | the ONE Application (`platform-data-kb-prod`, `directory.include: "*.yaml"`), enabled 2026-11-05 |

Shared platform files already carry the prep (inert until pods exist): namespace `kb-prod`
(platform/namespaces/onprem.yaml), the products-project destination (apps/project.yaml), the
`pg-kb-ca-pub` name in the cnpg-ca-prod store's RBAC (platform/eso/stores-onprem.yaml), and the
narrow `data-prod-kb-*` ingress policies (platform/networkpolicy/data-prod-kb.yaml).
`tei-e5-clients` already admits kb-prod on 80 (platform/ai/tei-e5.yaml:335).

values/kb/prod.yaml (the app), prod.secrets.yaml (the KV names) and tags.prod.yaml (provisional
digests) are the other half; the appset row is a comment in appsets/products.yaml.

## Owner prerequisites (the move PR lists these)

1. **Identity** — infra#342: the "KB Prod" sign-in app and the "KB Prod Service" mail app are
   applied (2026-11-05) and their client ids are in values/kb/prod.yaml. The redirect URIs are
   `https://kb.qnsc.vn/api/v1/auth/entra/callback` and
   `https://kb.qnsc.vn/api/v1/connectors/oauth/callback`.
2. **Key Vault** — `platform/bootstrap/secrets.sh --product kb --env prod --vault-app kv-qnsc-prod
   --skip-site`: the ten `kb-prod-*` names in values/kb/prod.secrets.yaml (the Graph
   certificate comes from the identity lane).
3. **R2** — create the bucket `qnsc-kb-prod-sources` (infra live/storage-prod) and a bucket-scoped
   token for kb-prod-r2-access-key-id / kb-prod-r2-secret-access-key.
4. **Mail** — Exchange RBAC scope for `noreply-kb@qnsc.vn` (the prod mail script), at least a day
   before cutover.
5. **Infra / backups** — add the 14-day lock rule for `pg-kb/pg-kb-g1/wals/` to
   `live/onprem/backups.tf` BEFORE the first backup (same one-line rule as pg-rova/pg-opshub).
6. **SA** — `cluster.sh --env prod --pg-cluster pg-kb` creates `pg-kb-ca` / `pg-kb-ca-pub` in
   data-prod from the same kv-qnsc-prod CA the other clusters use.
7. **Edge** — infra#343: `kb.qnsc.vn` in `app_hosts` with `access = "staff"` and `web = "cluster"`,
   plus the tunnel catch-all -> `web.kb-prod.svc:8080` (SA's live/onprem PR).
8. **Node headroom** — k3s-01 was at 67% of its memory requests on 2026-11-05 and falling after
   the prod right-size (gitops#318). kb prod adds ~3.6 Gi of requests (api 0.25 Gi + worker 1 Gi +
   web 64 Mi + pg-kb 2 Gi + valkey 0.25 Gi + the backup sidecars); confirm the headroom on the
   day, and watch memory pressure/OOM kills through the soak (limits still overcommit the node).

## To enable (order)

1. Merge the shared platform files (namespace, project destination, ESO RBAC, ingress policies) —
   they are inert.
2. `git mv platform/data/kb-prod/application.yaml.disabled apps/platform-data-kb-prod.yaml`; wait
   for pg-kb Healthy, run a backup and the restore test (REQUIRE_DATA=0, then 1 after ingest).
3. Uncomment the kb row in appsets/products.yaml (chart 0.19.3), set the real digests in
   tags.prod.yaml, and open the go-live PR once the placeholder gate passes.
