# Apps start from scratch, with Postgres on CloudNativePG

Postgres runs in the cluster on CloudNativePG (CNPG), and each app that needs it brings its own `postgresql.cnpg.io` `Cluster` in its `app/` directory. The external Postgres (`db-1.cluster.lorenzolab.com`) and Redis are not used. The operator lives in `cnpg-system`, and every app with a database `dependsOn` both `cloudnative-pg` and `longhorn`.

## Considered options

- **Use the external Postgres/Redis.** This needs no new component, but the database would live outside Git and outside the cluster's lifecycle.
- **One shared CNPG `Cluster` for all apps.** This uses less memory on small nodes, but couples every app's upgrades, restores and outages together. CNPG's model is one cluster per app.

## Consequences

- Each database costs a Postgres pod per instance, plus a Longhorn volume. While all VMs share one host, one instance per app is enough. Longhorn already keeps 2 replicas, and more CNPG instances would not add real redundancy.
- CNPG backups go through the Barman Cloud plugin to S3-compatible storage ([ADR 0003](0003-backups-to-r2.md)).
- Monitoring (PodMonitors) waits for `kube-prometheus-stack`.
