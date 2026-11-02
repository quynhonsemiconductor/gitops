# Keep pg-rova's data when its claim goes away (audit G-03)

Run by the SA/owner once, on k3s-01. Read-only first; the patch changes only a PV field and does not
touch the PVC, the pod or the data. Nothing here recreates a PVC.

```bash
# 1. which volumes back pg-rova, and their current policy (expect Delete, class local-path)
kubectl -n data-prod get pvc -l cnpg.io/cluster=pg-rova \
  -o custom-columns=PVC:.metadata.name,PV:.spec.volumeName,CLASS:.spec.storageClassName
kubectl get pv -o custom-columns=PV:.metadata.name,POLICY:.spec.persistentVolumeReclaimPolicy,CLAIM:.spec.claimRef.name,NS:.spec.claimRef.namespace \
  | grep -E 'PV|data-prod'

# 2. set Retain on exactly those PVs (pg-rova-1 data, pg-rova-1-wal)
for pvc in $(kubectl -n data-prod get pvc -l cnpg.io/cluster=pg-rova -o name); do
  pv=$(kubectl -n data-prod get "$pvc" -o jsonpath='{.spec.volumeName}')
  echo "retain $pv ($pvc)"
  kubectl patch pv "$pv" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
done

# 3. verify: every data-prod PV says Retain
kubectl get pv -o custom-columns=PV:.metadata.name,POLICY:.spec.persistentVolumeReclaimPolicy,NS:.spec.claimRef.namespace \
  | grep -E 'POLICY|data-prod'
```

pg-dev's PVs (data-dev) can be patched the same way with `-n data-dev -l cnpg.io/cluster=pg-dev`; they are
not part of this change.

After a PV is Retained and its claim is deleted, the PV shows `Released` and the directory stays under
the local-path root on the node. To reuse or free it: back up the directory, remove the PV's `claimRef`
(or delete the PV), and delete the directory yourself. New pg-rova PVCs (a rebuild) use the
`local-path-retain` StorageClass and need no patch.
