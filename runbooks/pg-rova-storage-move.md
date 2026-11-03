# Move pg-rova from `local-path` to `local-path-retain` (CNPG replace-by-replica)

Why: pg-rova's live PVCs were created on `local-path` (reclaimPolicy Delete) before the `local-path-retain`
class existed (audit G-03, gitops#96). CNPG never rewrites an existing PVC, so the only supported way to change a
volume's class is to **let CNPG build a new instance** (it takes the class from the Cluster spec, which already
says `local-path-retain` for `storage` and `walStorage`), **promote it**, and **remove the old instance**.

Downtime: the switchover only (a few seconds of failed writes; rova retries). Nothing else restarts.
Run by the SA/owner on k3s-01. Two PRs, in order. **Never merge PR B before step 6.**

| PR | Change | When it may merge |
|---|---|---|
| A (`feat/pg-rova-add-replica`) | `instances: 1` to `2`, plus this runbook | after steps 1-2 of the preconditions |
| B (`feat/pg-rova-instances-1`, stacked on A) | `instances: 2` to `1` | only after step 6 (switchover done and verified) |

## How CNPG chooses what to remove (read from the source, v1.30.1)

`internal/controller/replicas.go` `findDeletableInstance`: on scale-down CNPG considers only pods that are **Ready,
active and not the primary**, and among them removes the one with the **highest serial** (`pg-rova-2` beats
`pg-rova-1`). A pod that is not running is removed first. It never removes the primary.

So with two instances the result depends only on who is primary at the moment PR B syncs:

- primary = `pg-rova-2` (after the switchover): the only candidate is `pg-rova-1`, the OLD instance. **This is the
  intended outcome**, and the order of steps below guarantees it.
- primary = `pg-rova-1` (switchover not done or reverted): the candidate is `pg-rova-2`, the NEW one. **Wrong.**
  Hence the hard gate in step 6, and the check before merging B.

`ensureInstanceIsDeleted` then deletes the instance's PVC group (data and WAL PVCs) and its pod. The PVs of the old
instance are `Retain`, so they go to `Released` and the data stays on disk (step 9).

## Preconditions (all must hold; stop otherwise)

```bash
export KUBECONFIG=...            # k3s-01
NS=data-prod; C=pg-rova

# 1. cluster healthy, one primary, WAL archiving OK
kubectl -n $NS get cluster $C -o jsonpath='{.status.phase}{"\n"}{.status.currentPrimary}{"\n"}'
kubectl cnpg status $C -n $NS    # plugin; or: kubectl -n $NS get cluster $C -o yaml | less

# 2. the OLD PVs are Retain (runbooks/pv-retain.md). If any says Delete, patch it FIRST.
for pvc in $(kubectl -n $NS get pvc -l cnpg.io/cluster=$C -o name); do
  pv=$(kubectl -n $NS get "$pvc" -o jsonpath='{.spec.volumeName}')
  kubectl get pv "$pv" -o custom-columns=PV:.metadata.name,POLICY:.spec.persistentVolumeReclaimPolicy,CLASS:.spec.storageClassName
done
```

3. **A fresh backup and dump exist.** On-demand base backup (wait for `completed`), then the dump CronJob once:

```bash
kubectl -n $NS apply -f - <<'EOF'
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata: { name: pg-rova-pre-move, namespace: data-prod }
spec:
  cluster: { name: pg-rova }
  method: plugin
  pluginConfiguration: { name: barman-cloud.cloudnative-pg.io }
EOF
kubectl -n $NS get backup pg-rova-pre-move -w          # phase: completed
kubectl -n $NS create job --from=cronjob/pg-rova-dump pg-rova-dump-pre-move
kubectl -n $NS wait --for=condition=complete job/pg-rova-dump-pre-move --timeout=15m
```

4. **Disk.** The new instance takes a full copy (data 20 Gi + WAL 8 Gi, bounded by the real DB size). On the node,
   free space under the local-path root must exceed 2x the database size plus headroom:

```bash
kubectl -n $NS exec pg-rova-1 -c postgres -- du -sh /var/lib/postgresql/data/pgdata
# on k3s-01 (the filesystem the local-path provisioner uses; default /var/lib/rancher/k3s/storage):
df -h /var/lib/rancher/k3s/storage
```

5. **Room on the node for a second instance** (requests 500m CPU / 2 Gi, limit 2 Gi memory):

```bash
kubectl describe node k3s-01 | sed -n '/Allocated resources/,/Events/p'
```

6. Single-node facts, all fine for the move: both instances run on k3s-01 (CNPG's pod anti-affinity is `preferred`
   by default, so the replica may share the node; a `required` rule would leave it Pending, and the spec does not set
   one). The `data-prod-admit` NetworkPolicy already admits same-namespace pods (replication) and cnpg-system on
   5432/8000. With two instances CNPG creates PodDisruptionBudgets for the primary; they only matter for a node
   drain, not for this procedure. This is **not** an HA setup: two instances on one node are a migration tool.

## Procedure

**1. Merge PR A.** ArgoCD (`platform-data-prod`) syncs `instances: 2`. CNPG creates `pg-rova-2` (a join job runs
`pg_basebackup`, then the replica streams).

**2. Confirm the new PVCs use the retain class**, and wait for the replica:

```bash
kubectl -n $NS get pvc -l cnpg.io/cluster=$C \
  -o custom-columns=PVC:.metadata.name,CLASS:.spec.storageClassName,PV:.spec.volumeName,STATUS:.status.phase
#   pg-rova-1, pg-rova-1-wal  local-path         (old)
#   pg-rova-2, pg-rova-2-wal  local-path-retain  (new)   <- must be this class, both
kubectl get pv | grep data-prod          # new PVs: RECLAIM POLICY Retain
kubectl -n $NS get pods -l cnpg.io/cluster=$C -L role
kubectl cnpg status $C -n $NS            # "Streaming Replication status": pg-rova-2 state=streaming, sync lag 0 / replay lag small
```

If `pg-rova-2-*` came up on `local-path`, STOP: do not continue (the PVs would be Delete again); report.

**3. Streaming and caught up.** Re-run the status until `pg-rova-2` shows `streaming` and replay lag is ~0 and
`kubectl -n $NS get cluster $C` says `Cluster in healthy state` with 2 ready instances. Also run one
`kubectl -n $NS get backup` / confirm WAL archiving is still `OK` in `cnpg status`.

**4. Switchover to `pg-rova-2`** (the only step with downtime; do it in a quiet minute):

```bash
kubectl cnpg promote $C pg-rova-2 -n $NS
# without the plugin (fallback, the same thing the plugin does: set the target primary in the status):
# kubectl -n $NS patch cluster $C --subresource=status --type=merge -p '{"status":{"targetPrimary":"pg-rova-2"}}'
```

**5. Verify the switchover.**

```bash
kubectl -n $NS get cluster $C -o jsonpath='{.status.currentPrimary}{"\n"}'     # pg-rova-2
kubectl -n $NS get pods -l cnpg.io/cluster=$C -L role                          # pg-rova-2 primary, pg-rova-1 replica
kubectl cnpg status $C -n $NS                                                  # pg-rova-1 streaming from pg-rova-2
curl -s -o /dev/null -w '%{http_code}\n' https://rova.qnsc.vn/readyz           # 200, database green
```

**6. GATE before PR B.** `currentPrimary` is `pg-rova-2`, pg-rova-1 is a streaming replica, `/readyz` is 200, and
the rova logs show no sustained database errors. Wait a few minutes (let a few requests and one WAL archive pass).
If anything is off, roll back by promoting pg-rova-1 again (`kubectl cnpg promote $C pg-rova-1 -n $NS`) and stop:
PR B is not merged.

**7. Merge PR B** (retarget it to `main` after A merged). `instances: 1`: CNPG applies `findDeletableInstance`
and removes **pg-rova-1**. Watch it:

```bash
kubectl -n $NS get events --sort-by=.lastTimestamp | grep -i "scal"
#   Scaling down - removing instance: pg-rova-1      <- must say pg-rova-1. If it says pg-rova-2, see below.
```

If the event names `pg-rova-2` (the primary was not pg-rova-2 when B synced): CNPG never removes the primary, so it
removed the new replica. Nothing is lost (it was a replica and its PVs are Retain), but the move is not done:
set `instances: 2` again via a revert of B and restart from step 2. If you ever need to choose the instance by
hand instead (the pattern CNPG documents for replacing a node's storage), do it on a REPLICA only: after the
switchover, `kubectl -n $NS delete pvc pg-rova-1 pg-rova-1-wal --wait=false && kubectl -n $NS delete pod pg-rova-1`;
CNPG then rebuilds an instance only if the live count is below `instances`, so lower `instances` to 1 in the same
change (PR B) first.

**8. Verify the end state.**

```bash
kubectl -n $NS get cluster $C                                   # 1 instance, healthy, primary pg-rova-2
kubectl -n $NS get pvc -l cnpg.io/cluster=$C \
  -o custom-columns=PVC:.metadata.name,CLASS:.spec.storageClassName      # pg-rova-2, pg-rova-2-wal, local-path-retain
argocd app get platform-data-prod                                # Synced / Healthy. The permanent OutOfSync (gitops#96) is gone.
curl -s -o /dev/null -w '%{http_code}\n' https://rova.qnsc.vn/readyz
# next morning: the 02:00 ICT nightly Backup (pg-rova-nightly) is completed, and the 03:00 ICT pg-rova-dump Job succeeded
kubectl -n $NS get backup; kubectl -n $NS get jobs | grep pg-rova-dump
```

Record, before step 1, what `argocd app diff platform-data-prod` shows; after step 8 it must be empty. If the
OutOfSync is still there, it was not the PVC class and needs its own look.

**9. Clean up the old volumes, only after step 8 and one good backup.** The old PVs are `Released` (Retain). They
hold the pre-move data: that is the rollback until you delete them.

```bash
kubectl get pv | grep -E 'Released.*data-prod/pg-rova-1'          # note the two PV names
# the directories live on k3s-01 under the local-path root, named pvc-<uid>_data-prod_pg-rova-1[ -wal ]
kubectl get pv <pv> -o jsonpath='{.spec.local.path}{.spec.hostPath.path}{"\n"}'
# when sure: delete the PV objects, then the directories on the node
kubectl delete pv <pv-data> <pv-wal>
sudo rm -r <that path for each>          # irreversible; check the path twice
```

## Not covered

- High availability (two instances on one node is not HA). A real second node is a separate decision.
- pg-dev and pg-opshub keep their classes; the same procedure applies if wanted (`pg-opshub` has no live prod yet).
