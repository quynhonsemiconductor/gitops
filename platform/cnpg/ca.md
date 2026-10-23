# The static CNPG CA (on-prem, 2026-10-23 — provided-CA mode, final)

The CA never rotates in place (plan §5.6). One 10-year keypair per env, generated ONCE on the
operator laptop and stored in `kv-qnsc-admin` as ONE secret (crt + key); the laptop copies are
deleted after upload. Nothing ever renews the CA.

```bash
# one CA per env; 3650 days ≈ 10 years; then DELETE both files after az upload
openssl req -x509 -newkey rsa:3072 -days 3650 \
  -subj "/CN=qnsc-cnpg-ca-<env>" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -keyout ca-<env>.key -out ca-<env>.crt

# upload as ONE vault secret (crt then key), then shred the copies
cat ca-<env>.crt ca-<env>.key   | az keyvault secret set --vault-name kv-qnsc-admin \
      --name platform-cnpg-ca-<env> --file /dev/stdin \
      --tags owner=platform rotate-by="$(date -v+9y +%Y-%m-%d)" -o none
rm -P ca-<env>.key ca-<env>.crt   # rm -P = overwrite before unlink (macOS)
```

Apply at bootstrap/rebuild via stdin (runbook §14 Bước 2) into `data-<env>`:

```bash
kubectl -n data-<env> create secret generic <cluster>-ca \
  --from-file=ca.crt=<(awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' /dev/stdin) \
  --from-file=ca.key=<(awk '/BEGIN PRIVATE KEY/,/END PRIVATE KEY/' /dev/stdin)
kubectl -n data-<env> create secret generic <cluster>-ca-pub \
  --from-file=ca.crt=<(awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' /dev/stdin)
```

- `<cluster>` is `pg-rova` (data-prod) / `pg-dev` (data-dev).
- **Provided-CA mode:** the cluster pins ONLY `spec.certificates.serverCASecret: <cluster>-ca`
  (crt + key). There is NO `serverTLSSecret`: CNPG issues and renews the server certificate from
  this CA itself (~90 days), and its SANs cover `<cluster>-rw`, `-r`, `-ro` and the FQDNs.
- Apps pin the CA via the `<cluster>-ca-pub` mirror (`ca.crt` only — the `cnpg-ca-<env>`
  ClusterSecretStore RBAC admits exactly that Secret name); the chart's `<product>-db-ca`
  ExternalSecret mirrors it with a 12 h refresh.
- No cert-manager for the CNPG CA (it still runs for the barman plugin's mTLS), no Reloader,
  no `ca-sync`.
- A future CA swap = planned maintenance window (§16.2): new CA from the vault applied to both
  Secrets, products rolled, cluster rolled. Never restart `pg-rova` from old PVCs after a rollback —
  plan §10.5.
