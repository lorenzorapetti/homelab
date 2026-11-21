---
sidebar_position: 5.75
sidebar_label: "Backups: volumes"
---

# Backups: volumes

[VolSync](https://volsync.readthedocs.io/) backs up app PVCs to Cloudflare R2 with restic ([ADR 0003](https://github.com/lorenzorapetti/homelab/blob/main/docs/adr/0003-backups-to-r2.md)). Postgres doesn't go through it: databases have their own [WAL-based backups](/kubernetes/backups-postgres).

## As built

- **The operator**: chart `0.17.0` from backube's Helm repository (no OCI chart), in `volsync-system`. Files: `kubernetes/apps/volsync-system/volsync/`.
- **One `ReplicationSource` per PVC**, from the component `kubernetes/components/volsync`. Every night (03:30 UTC by default) it:
  1. clones the PVC (`copyMethod: Clone`, a Longhorn CSI clone), so restic reads a point-in-time copy and the mover pod doesn't need the app's node;
  2. runs restic against `s3://<bucket>/<app>/volsync`, keeping 7 daily, 4 weekly and 3 monthly snapshots, pruned weekly;
  3. deletes the clone.
- **The restic Secret** (`<app>-volsync`) is a plain manifest in the component, filled in by Flux's postBuild substitution: the endpoint and bucket from `cluster-secrets`, the R2 token from `r2-backup`, and the repository password from `volsync-restic`. That password is shared by every app; it's in `kubernetes/components/r2-backup/restic.sops.yaml`. **Without it the backups can't be read**: it lives in Git (SOPS) and nowhere else.
- **Why Clone and not Snapshot**: `Snapshot` needs the external snapshot-controller, its CRDs and a `VolumeSnapshotClass`, none of which the cluster has. Longhorn clones natively. Both copy the whole volume on Longhorn, so a clone costs no more.

The volumes today:

| PVC | Namespace | Backups on R2 |
| --- | --- | --- |
| `forgejo` | `git` | `s3://<bucket>/forgejo/volsync` |

## Backing up a new app's PVC

1. The namespace's `kustomization.yaml` includes the `r2-backup` component (it brings `r2-backup` and `volsync-restic`).
2. The app's `kustomization.yaml` includes `../../../../components/volsync`.
3. Its `ks.yaml` gets:

   ```yaml
     dependsOn:
       - name: volsync
         namespace: volsync-system
     postBuild:
       substitute:
         APP: <pvc name>          # also the ReplicationSource's name and the R2 path
         # VOLSYNC_PUID / VOLSYNC_PGID: the uid/gid that owns the files (default 1000)
         # VOLSYNC_SCHEDULE: a cron schedule (default "30 3 * * *")
       substituteFrom:
         - name: cluster-secrets
           kind: Secret
         - name: r2-backup
           kind: Secret
         - name: volsync-restic
           kind: Secret
   ```

4. Add a row to the table above.

## Checking that backups work

All commands run inside `devenv shell`.

```sh
kubectl get replicationsource -A
kubectl -n git get replicationsource forgejo -o jsonpath='{.status.lastSyncTime}{"  "}{.status.latestMoverStatus.result}{"\n"}'
```

`lastSyncTime` should be from last night and `result` `Successful`. The mover's log (`latestMoverStatus.logs`) ends with restic's summary. To run one now instead of waiting for the schedule:

```sh
kubectl -n git patch replicationsource forgejo --type merge -p '{"spec":{"trigger":{"manual":"'"$(date +%s)"'"}}}'
```

While `trigger.manual` is set the schedule is ignored, and Flux doesn't remove a field it didn't set. Remove it once the run is done:

```sh
kubectl -n git patch replicationsource forgejo --type json -p '[{"op":"remove","path":"/spec/trigger/manual"}]'
```

## Restoring

Into the existing PVC, with the app stopped so nothing writes to it. Suspend its HelmRelease first, or Flux scales it back up:

```sh
flux suspend hr forgejo -n git
kubectl -n git scale deploy forgejo --replicas 0
```

Then apply:

```yaml
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: forgejo-restore
  namespace: git
spec:
  trigger:
    manual: restore-1
  restic:
    repository: forgejo-volsync
    destinationPVC: forgejo
    copyMethod: Direct
    # restoreAsOf: "2026-11-22T00:00:00Z"   # optional: the last snapshot before this time
    moverSecurityContext:
      runAsUser: 1000
      runAsGroup: 1000
      fsGroup: 1000
```

Wait for `.status.latestMoverStatus.result` to be `Successful`, delete the `ReplicationDestination`, and `flux resume hr forgejo -n git`, which scales it back to one replica.

The repository can also be opened from any machine with restic, using the four values in Secret `forgejo-volsync`.

## Alerts

From `kubernetes/apps/volsync-system/volsync/app/prometheusrule.yaml`:

| Alert | Fires when | For | Severity | What to do |
| --- | --- | --- | --- | --- |
| `VolSyncVolumeOutOfSync` | A ReplicationSource missed its scheduled backup | 30m | warning | `kubectl describe replicationsource` and the `volsync-src-*` mover pod's logs. Usual causes: R2 unreachable, a stale restic lock (`restic unlock` with the Secret's values), the clone failing in Longhorn |
| `VolSyncDown` | No VolSync metrics | 15m | warning | The `volsync` Deployment in `volsync-system`. Until it's back, out-of-sync volumes go unnoticed |
