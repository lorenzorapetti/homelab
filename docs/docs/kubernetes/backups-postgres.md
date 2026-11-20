---
sidebar_position: 5.7
sidebar_label: "Backups: Postgres"
---

# Backups: Postgres

Every Postgres database runs on CloudNativePG (CNPG), one `Cluster` per app ([ADR 0002](https://github.com/lorenzorapetti/homelab/blob/main/docs/adr/0002-cloudnativepg-fresh-start.md)). The Barman Cloud plugin backs each one up to Cloudflare R2 ([ADR 0003](https://github.com/lorenzorapetti/homelab/blob/main/docs/adr/0003-backups-to-r2.md)):

- **WAL archiving** runs all the time. Postgres hands every finished WAL segment to the plugin's sidecar, which uploads it. CNPG forces a segment switch at least every 5 minutes, so at most about 5 minutes of writes are not yet in R2.
- **A base backup** runs every night at 03:00 UTC (`ScheduledBackup`), and once right after the `ScheduledBackup` is created.
- **Retention** is a 30-day recovery window, set on the `ObjectStore`. The plugin deletes backups that are no longer needed for it.

A restore replays WAL on top of a base backup, so it can stop at any point in time inside the window, not only at a nightly backup.

Today the only database is `authentik-db` in `auth`. Its files are in `kubernetes/apps/auth/authentik/db/`. Its backups are under `s3://<bucket>/authentik/authentik-db/` on R2.

All commands below run inside `devenv shell` (bash), which provides `kubectl`, `jq` and `flux`.

## Checking that backups work

The Cluster's conditions say whether archiving and the last backup worked:

```sh
kubectl get cluster authentik-db -n auth -o json \
  | jq -r '.status.conditions[] | "\(.type)=\(.status)  \(.message)"'
```

`ContinuousArchiving=True` and `LastBackupSucceeded=True` are what you want.

The `ObjectStore` shows the recovery window, which is the range of times you can restore to:

```sh
kubectl get objectstore authentik-r2 -n auth -o jsonpath='{.status.serverRecoveryWindow}'; echo
```

The base backups (use the full name: `kubectl get backup` finds Longhorn's `backups` resource, not CNPG's):

```sh
kubectl get backups.postgresql.cnpg.io -n auth
```

Postgres's own view of archiving, on the primary:

```sh
PRIMARY=$(kubectl get cluster authentik-db -n auth -o jsonpath='{.status.currentPrimary}')
kubectl exec -n auth "$PRIMARY" -c postgres -- psql -U postgres -At \
  -c 'select last_archived_wal, last_archived_time, failed_count, last_failed_wal from pg_stat_archiver;'
```

`last_archived_time` should be less than about 5 minutes old, and `failed_count` should not grow. If archiving fails, the plugin sidecar's log says why:

```sh
kubectl logs -n auth "$PRIMARY" -c plugin-barman-cloud --tail=50
```

## Restore test

This rebuilds a throwaway copy of `authentik-db` from R2, next to the live one, and compares the two. It changes nothing in Git, and nothing in the live database. Run it after any change to the backup setup, and from time to time anyway: a backup counts only once a restore from it has worked.

The copy goes in the same namespace as the live database, `auth`, because the plugin reads the `ObjectStore` and the `r2-backup` Secret from the restoring Cluster's namespace.

### 1. Record the live state

Take a few numbers that change as authentik is used. Rows written after the last base backup prove that WAL replay works, not just the base backup.

```sh
q() {
  kubectl exec -n auth "$1" -c postgres -- psql -U postgres -d authentik -At -F ' | ' \
    -c 'select count(*), max(date_joined) from authentik_core_user;' \
    -c 'select count(*), max(created) from authentik_events_event;' \
    -c 'select count(*) from django_migrations;' \
    -c "select pg_size_pretty(pg_database_size('authentik'));"
}
q "$(kubectl get cluster authentik-db -n auth -o jsonpath='{.status.currentPrimary}')"
```

### 2. Create the copy

```sh
kubectl apply -f - <<'EOF'
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: authentik-db-restore-test
  namespace: auth
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:18.7-minimal-trixie
  bootstrap:
    recovery:
      source: authentik-db-r2
      database: authentik
      owner: authentik
  externalClusters:
    - name: authentik-db-r2
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: authentik-r2
          serverName: authentik-db
  storage:
    storageClass: longhorn
    size: 5Gi
EOF
kubectl wait cluster/authentik-db-restore-test -n auth --for=condition=Ready --timeout=15m
```

**The manifest has no `plugins:` section, on purpose.** Without it the copy archives nothing, so it can't write into the live database's backups. Never give a copy `plugins:` with `barmanObjectName: authentik-r2` and no other `serverName`, because it would then archive into `authentik-db`'s folder.

The `imageName` must be the same Postgres major version as the live Cluster (`kubernetes/apps/auth/authentik/db/cluster.yaml`).

### 3. Compare

```sh
q authentik-db-restore-test-1
```

The output must match step 1, minus anything written in the last few minutes (WAL not yet archived).

`pg_stat_archiver` on the copy may show some archived and failed WAL files. That is CNPG's own `wal-archive` command running with no archiver configured, and it uploads nothing. The copy's pod has only the `postgres` container, with no plugin sidecar and no R2 credentials.

### 4. Delete the copy

```sh
kubectl delete cluster authentik-db-restore-test -n auth --wait=true
kubectl get pvc -n auth     # authentik-db-restore-test-1 goes away a few seconds later
```

### Results

| Date | Base backup | Restored to | Took | Result |
| --- | --- | --- | --- | --- |
| 2026-11-20 | 09:45 UTC (the first one) | latest WAL, about 10:10 UTC | under 2 min, 29 MB | Pass. Users, the `lorenzo` login at 09:53, 11 events up to 09:58 and 777 migrations all matched the live database. Everything after 09:45 came from WAL replay. |

## Restoring to a point in time

To get the database as it was at a given time, for example just before a bad change, add a `recoveryTarget` to the copy in step 2 of the restore test:

```yaml
  bootstrap:
    recovery:
      source: authentik-db-r2
      database: authentik
      owner: authentik
      recoveryTarget:
        targetTime: "2026-11-20 09:55:00+00"
```

The time must be inside the recovery window. You can then inspect the copy, or dump a table from it with `pg_dump` and load that into the live database. **Not yet tested here.**

## Replacing a lost database

Use this when `authentik-db` itself is gone or broken: the volume was lost, or the cluster was rebuilt from scratch. **This procedure is not yet tested here.** Run the restore test first, to make sure the backups are good.

You can't restore a `Cluster` in place. `bootstrap` only runs when a Cluster is created, so the broken Cluster is deleted and a new one with the same name is created from R2.

The new Cluster must archive to a new folder. Its WAL timeline starts where the old one stopped, and the plugin won't archive into a folder that already holds another server's WAL. The plugin's `serverName` parameter in `.spec.plugins` gives the new folder its name. Recovery still reads the old one (`authentik-db`).

### 1. Stop Flux and authentik

```sh
flux suspend kustomization authentik -n auth
flux suspend kustomization authentik-db -n auth
kubectl scale deploy authentik-server authentik-worker -n auth --replicas=0
```

With authentik scaled down, nothing writes to the database while it is replaced.

### 2. Delete the broken Cluster

Delete it only after you have checked the recovery window (see [Checking that backups work](#checking-that-backups-work)). This also deletes its volume.

```sh
kubectl delete cluster authentik-db -n auth --wait=true
```

### 3. Change `cluster.yaml` to restore from R2

In `kubernetes/apps/auth/authentik/db/cluster.yaml`, replace `bootstrap.initdb`, and add `serverName` to the plugin:

```yaml
  bootstrap:
    recovery:
      source: authentik-db-r2
      database: authentik
      owner: authentik
      # recoveryTarget: {targetTime: "..."}   # optional, see above
  externalClusters:
    - name: authentik-db-r2
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: authentik-r2
          serverName: authentik-db           # read from the old folder
  plugins:
    - name: barman-cloud.cloudnative-pg.io
      isWALArchiver: true
      parameters:
        barmanObjectName: authentik-r2
        serverName: authentik-db-2           # write to a new folder
```

Commit and push.

### 4. Bring the database back, then authentik

```sh
flux resume kustomization authentik-db -n auth
kubectl wait cluster/authentik-db -n auth --for=condition=Ready --timeout=20m
flux resume kustomization authentik -n auth
kubectl rollout restart deploy authentik-server authentik-worker -n auth
```

The restart matters. CNPG writes the app user's password into a new `authentik-db-app` Secret, and authentik reads it only when a pod starts.

### 5. Take a base backup right away

The `ScheduledBackup` only runs immediately when it is created, so start one by hand. Until it finishes, the new folder has WAL but no base backup to replay it on.

```sh
kubectl apply -f - <<'EOF'
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: authentik-db-after-restore
  namespace: auth
spec:
  cluster:
    name: authentik-db
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF
kubectl get backups.postgresql.cnpg.io -n auth -w
```

Leave `bootstrap.recovery` in `cluster.yaml`. CNPG ignores `bootstrap` on an existing Cluster, and if the Cluster is ever lost again it restores from R2 again instead of starting empty. Point `externalClusters` at `authentik-db-2` then, and archive to `authentik-db-3`.

The old `authentik-db/` folder stays in R2. Delete it by hand once the new folder's recovery window covers what you need.
