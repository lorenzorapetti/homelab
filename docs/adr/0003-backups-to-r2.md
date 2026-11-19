# Backups go straight to Cloudflare R2

The cluster writes every backup to one S3 bucket on Cloudflare R2, offsite. Postgres is backed up by the CloudNativePG Barman Cloud plugin, which archives WAL continuously and takes scheduled base backups, so a database can be restored to any point in time. Other PVCs are backed up by VolSync with the restic mover. Each app writes under its own path in the bucket.

## Considered options

- **A bucket on the NAS, copied by the NAS to R2.** Restores would be faster, and the backups would survive an R2 outage. But it adds a service and a sync job to run at home, for databases small enough to download quickly. It can be added later by changing each `ObjectStore`'s endpoint.
- **An S3 server in the cluster, on Longhorn.** Every Longhorn replica sits on the same SSD as the data being backed up, and restoring would need the very cluster that failed. It isn't a backup.
- **Backblaze B2.** It costs about the same, but R2 has free egress, so restores and restore tests cost nothing, and the Cloudflare account already exists for DNS.
- **Longhorn's built-in backups instead of VolSync.** These need no extra operator, but data leaves the cluster unencrypted and only Longhorn can read it back. restic encrypts before upload, and its repository can be opened from any machine.
- **Volume snapshots for Postgres.** These copy files that may be mid-write. Barman's WAL archive gives consistent, point-in-time restores.

## Consequences

- Each app with a database has its own `ObjectStore` (path `s3://<bucket>/<app>`) and a `ScheduledBackup`. Retention is set on the `ObjectStore` and enforced by the plugin.
- One R2 API token, scoped to the backup bucket, sits in the cluster as a SOPS secret. Anyone holding it can also delete backups. An R2 bucket lock rule can protect objects for a minimum age, if that becomes a concern.
- Barman files reach R2 unencrypted on the client side. R2 encrypts at rest, and SSE-C (`sseCustomerKey`) is available if that isn't enough. restic data is encrypted by VolSync.
- Restores need internet access. If the uplink is down, there's no restore.
- A backup counts only once a restore from it has been tested.
