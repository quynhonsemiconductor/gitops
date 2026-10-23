# The static CNPG CA (on-prem, 2026-10-23)

The CA never rotates in place (plan §5.6). One 10-year CA per env, created once at
bootstrap on the operator laptop, from material that lives in `kv-qnsc-admin`:

```bash
# one CA per env; 3650 days ≈ 10 years
openssl req -x509 -newkey rsa:3072 -nodes -days 3650 \
  -subj "/CN=qnsc-cnpg-ca-<env>" -keyout ca-<env>.key -out ca-<env>.crt
```

Apply into `data-<env>` (CNPG's format: one Secret with `ca.crt` + `ca.key`,
named after the cluster) and the product-readable mirror (`ca.crt` only — the
`cnpg-ca-<env>` ClusterSecretStore RBAC admits exactly this Secret name):

```bash
kubectl -n data-<env> create secret generic <cluster>-ca \
  --from-file=ca.crt=ca-<env>.crt --from-file=ca.key=ca-<env>.key
kubectl -n data-<env> create secret generic <cluster>-ca-pub \
  --from-file=ca.crt=ca-<env>.crt
```

- `<cluster>` is `pg-rova` (data-prod) / `pg-dev` (data-dev).
- The cluster pins both via `spec.certificates.serverCASecret: <cluster>-ca`
  and `serverTLSSecret: <cluster>-server-cert` (CNPG issues the server cert
  from this CA; a SAN covers `<cluster>-rw/-ro/-r`).
- Copy the CA (cert only) into `kv-qnsc-admin` (`platform-cnpg-ca-<env>`) —
  the weekly restore test and a §14 rebuild need it.
- A future CA swap = planned maintenance window: new CA + server cert, apply
  both Secrets, roll the products (the chart's `db-ca` refresh is 12 h), then
  update the vault. Never restart `pg-rova` from old PVCs after a rollback —
  plan §10.5.
