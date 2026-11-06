# pg-coder (Coder control-plane database), data-prod

Born in the argocd-audit M2 data layout: one directory per data scope, one Application
(`apps/platform-data-coder-prod.yaml`, `directory.include: "*.yaml"`), the restore test
inside the same directory.

SA decision 2026-11-06 (R2 token audit): pg-coder lives HERE, in data-prod, with
pg-rova/pg-opshub/pg-kb — not in namespace `coder`. Its barman backup, dump and restore
test then use the prod R2 credentials that already exist in data-prod
(`r2-backup-rw` / `r2-dump-rw` / `r2-backup-ro` in kv-qnsc-prod): no `coder-r2-*` copies
in kv-qnsc-platform and one vault to rotate.

| File | What |
|---|---|
| `pg-coder.yaml` | CNPG cluster `pg-coder` (5 Gi + 2 Gi WAL on `local-path-retain`), roles `coder_migrator` (database owner, NOCREATEROLE) and `coder_readonly` (`pg_read_all_data`, the dump role), CA `pg-coder-ca` |
| `pg-coder-backup.yaml` | barman-cloud ObjectStore -> `s3://qnsc-backups/pg-coder/`, WAL archiving (serverName `pg-coder-g1`), nightly base backup 19:45 UTC |
| `pg-coder-dump.yaml` | nightly `pg_dump -Fc` in data-prod as `coder_readonly` -> `dumps/…/coder-YYYY-MM-DD.dump`, using the SHARED data-prod dump Secret `pg-dump-r2` |
| `role-secrets.yaml` | the two role passwords, mirrored from namespace `coder` (kv-qnsc-platform) through the `coder-db-secrets` kubernetes store — narrow RBAC, one source of truth |
| `restore-test-coder.yaml` | on-demand restore test in `restore-test` (suspended CronJob), incl. the role and ownership checks |

Owner prerequisites:

1. `platform/bootstrap/cluster.sh --env prod --pg-cluster pg-coder` creates `pg-coder-ca` /
   `pg-coder-ca-pub` in data-prod from the shared kv-qnsc-prod CA. The Cluster does not
   become Ready without it.
2. The R2 tokens are the existing prod ones — nothing new in the platform vault. The two
   DB passwords are the `coder-db-migrator` / `coder-db-readonly` keys in
   kv-qnsc-platform (seven coder secrets total, see `platform/coder/README.md`).

The namespace `coder` still holds the Coder server and its env Secret
(`CODER_PG_CONNECTION_URL`, OIDC) — see `platform/coder/database.yaml`.
