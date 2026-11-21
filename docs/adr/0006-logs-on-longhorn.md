# Loki keeps logs on a Longhorn volume, for 7 days

Loki runs as a single binary in `observability` and stores everything (WAL, TSDB index, chunks) on its filesystem, a 20Gi Longhorn volume. The compactor deletes logs older than 7 days, the same window as Prometheus's metrics. It is also how far back Loki accepts lines (`reject_old_samples_max_age: 168h`). Logs are not backed up.

This is the right trade-off because:

- **Logs are for debugging the recent past.** Like Prometheus's metrics, losing them with the cluster is acceptable. Nothing in them is a record I need to keep.
- **It works without the internet.** Logs are most useful when something is broken, and a broken uplink is one of those things. With object storage on R2, writes would back up and queries over older logs would fail exactly then.
- **It needs no new credentials.** The only R2 token in the cluster can read and delete every backup ([ADR 0003](0003-backups-to-r2.md)). Handing it to Loki would put the backups one compromised pod further away. A separate bucket and token would avoid that, but it's another secret to rotate.
- **The volume is small next to the free space.** Each Longhorn node has about 200 GB free, and 20Gi with two replicas is a fraction of it.

## Considered options

- **R2 as Loki's object store.** Loki's preferred backend: the volume holds only the WAL, and logs survive the cluster. It costs Class A operations for every chunk flush and compaction (within the free tier at homelab volume), needs the internet for every query of flushed data, and needs its own bucket and token (see above). It's the choice if logs ever need to outlive the cluster, for audit or for debugging a full rebuild.
- **MinIO in the cluster, on Longhorn.** Object storage without leaving the cluster, but a second stateful service on the same disks, for no gain over the filesystem in single-binary mode.
- **Simple-scalable mode.** Separate read, write and backend pods, which need object storage. Three or more pods on nodes with under 4 GB allocatable, for a log volume one pod handles.

## Consequences

- Retention is by age only. Loki has no size limit like Prometheus's `retentionSize`, so a log flood can fill the volume before 7 days pass. `KubePersistentVolumeFillingUp` (from kube-prometheus-stack) fires first, and the volume can be grown in place.
- One pod, one replica: while it restarts or moves nodes, Alloy buffers and retries, and queries fail. Lines that wait too long are dropped (`AlloyDroppingLogs`).
- Moving to R2 later means a new `schemaConfig` period with `object_store: s3` from a future date. Older logs stay on the filesystem until they age out.
