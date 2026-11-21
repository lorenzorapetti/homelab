---
sidebar_position: 7
sidebar_label: Logs
---

# Logs

Every pod's logs are in [Loki](https://grafana.com/oss/loki/) and can be searched in Grafana, next to the metrics. [Grafana Alloy](https://grafana.com/oss/alloy-opentelemetry-collector/) runs on every node, tails the log files the kubelet writes, and pushes them to Loki.

## Architecture

```
  node (×3)                                   observability
 ┌──────────────────────────────┐
 │ kubelet → /var/log/pods/…    │
 │              │ tail          │  push    ┌──────────────────────┐  query  ┌─────────┐
 │        Alloy (DaemonSet) ─────┼────────▶│ Loki (single binary) │◀────────│ Grafana │
 │   positions: /var/lib/alloy  │          │ 20Gi Longhorn PVC    │         └─────────┘
 └──────────────────────────────┘          └──────────────────────┘
```

Two Flux Kustomizations in `kubernetes/apps/observability/`:

| Kustomization | Path | What it deploys | Depends on |
| --- | --- | --- | --- |
| `loki` | `loki/app/` | `HelmRelease` `loki`, chart `7.7.0` from `oci://ghcr.io/grafana/helm-charts`; its `PrometheusRule`; the **Pod Logs** dashboard | `longhorn`, `prometheus-operator-crds` |
| `alloy` | `alloy/app/` | `HelmRelease` `alloy`, chart `1.16.0` (Alloy `v1.22.0`) from the same registry; its `PrometheusRule` | `loki`, `prometheus-operator-crds` |

### Loki

- **Single-binary mode**: one StatefulSet pod, `loki-0`, runs every Loki component. The chart's other targets, the nginx gateway, the memcached caches, the canary and the ruler are all off. At homelab volume one pod is plenty, and the caches alone would ask for 9 GB.
- **One tenant**: `auth_enabled: false`, so Alloy and Grafana send no `X-Scope-OrgID`.
- **Service**: `loki.observability.svc.cluster.local:3100` (HTTP API, push and query) and `:9095` (gRPC, internal).
- **Resources**: requests 50m / 256Mi, limit 1Gi, with `GOMEMLIMIT=900MiB` so Go collects garbage before the kernel kills it.

### Alloy

One pod per node (tolerates every taint), configured in River in the chart's `alloy.configMap.content`:

1. `discovery.kubernetes` lists the pods on its own node (`spec.nodeName=$HOSTNAME`; the chart sets `HOSTNAME` to the node name).
2. `discovery.relabel` turns pod metadata into labels and builds the file path `/var/log/pods/*<uid>/<container>/*.log`.
3. `local.file_match` and `loki.source.file` tail those files. Read positions are in `/var/lib/alloy` on the node (a hostPath), so a restarted pod carries on where it stopped.
4. `loki.process` with `stage.cri` parses the kubelet's CRI format: it keeps the message, uses the kubelet's timestamp and joins lines split by the runtime.
5. `loki.write` pushes to Loki.

Alloy reads `/var/log` from the host, so it needs `hostPath` volumes. The `observability` namespace is already `privileged` for node-exporter.

Alloy's UI (the component graph, each component's health and targets) is on port 12345: `kubectl port-forward -n observability ds/alloy 12345`, then `http://localhost:12345`.

### Labels

Every stream has these labels:

| Label | From |
| --- | --- |
| `namespace` | the pod's namespace |
| `pod` | the pod's name |
| `container` | the container's name |
| `app` | the first of the pod labels `app.kubernetes.io/name`, `app` and `k8s-app` that is set, else the container name |
| `node` | the node the pod runs on |
| `service_name` | added by Loki, from `app` (Grafana's Logs Drilldown groups by it) |

There are no labels from the log content (level, logger…). Parse those at query time (`| json`, `| logfmt`), so the number of streams stays small.

### What isn't collected

- **Talos node logs** (machined, apid, containerd, the kubelet, etcd) and the kernel ring buffer: read them with `talosctl logs <service>` and `talosctl dmesg`. Why they aren't shipped, and what it would take: [ADR 0007](https://github.com/lorenzorapetti/homelab/blob/main/docs/adr/0007-talos-node-logs-not-shipped.md). The control-plane static pods (kube-apiserver, kube-controller-manager, kube-scheduler) **are** collected: they're pods.
- **Kubernetes events**: they aren't logs. Use `kubectl events` or the pod's page in k9s.

## Storage and retention

Loki writes its WAL, TSDB index and chunks to its filesystem, a **20Gi Longhorn volume** (PVC `storage-loki-0`). Logs are kept for **7 days**, the same as Prometheus's metrics: the compactor marks older chunks and deletes them 2 hours later. Logs are **not backed up**. Why Longhorn and not R2: [ADR 0006](https://github.com/lorenzorapetti/homelab/blob/main/docs/adr/0006-logs-on-longhorn.md).

| Setting | Value | Where |
| --- | --- | --- |
| Retention | 7 days | `loki.limits_config.retention_period`, applied by `loki.compactor.retention_enabled` |
| Volume | 20Gi, `longhorn` | `singleBinary.persistence` |
| Schema | TSDB, v13, 24h index period, from 2026-11-21 | `loki.schemaConfig` |
| Oldest line accepted | 7 days | the chart's `reject_old_samples_max_age` |

Retention is by age only. A log flood can fill the volume before 7 days pass, and `KubePersistentVolumeFillingUp` fires before it's full. To grow it, raise `singleBinary.persistence.size`. Longhorn expands the volume online, but the chart can't change a StatefulSet's volume claim template: delete the StatefulSet with `--cascade=orphan` and let Flux recreate it, then patch the PVC's size.

Because the WAL is on the same volume, lines Loki accepted but hadn't flushed yet survive a restart.

## Grafana

Loki is a provisioned data source, **Loki** (uid `loki`), in kube-prometheus-stack's `grafana.additionalDataSources`.

### Reading logs

- **Explore** → data source **Loki**: write LogQL, or build the query with the label browser.
- **Drilldown → Logs** (Grafana's Logs Drilldown app): browse by `service_name`, with log volume, patterns and fields, and no LogQL needed.
- **Pod Logs** dashboard (`/d/pod-logs`, folder **Kubernetes**): pick a namespace, pods and containers, and an optional regex in **Line contains**. It shows log volume per container above the lines.

### From a metrics dashboard to logs

On **Cluster Health**, the pod columns of **Unhealthy pods**, **Container restarts in range**, **Last termination reason** and **Postgres instances** are links: click a pod, then **Logs of …**, to open **Pod Logs** for that namespace, pod (and container), over the same time range. The dashboard's link bar has **Pod Logs** too.

On the chart's dashboards (Kubernetes / Compute Resources / Pod, and so on), which are not ours to edit, use **Explore**: in a panel's menu, **Explore** opens its query; switch the data source to Loki and keep the time range. Or open **Pod Logs** and pick the pod.

To add the same link to another table with `namespace` and `pod` columns, give the pod column a field override:

```json
{ "matcher": { "id": "byName", "options": "Pod" }, "properties": [
  { "id": "links", "value": [ { "title": "Logs of ${__value.raw}",
    "url": "/d/pod-logs?var-namespace=${__data.fields.Namespace}&var-pod=${__value.raw}&${__url_time_range}" } ] }
] }
```

(`Namespace` and `Pod` are the column names after the table's `organize` transformation. Use the raw label names if the table doesn't rename them.)

### Example LogQL queries

```logql
# Everything authentik logs
{namespace="auth"}

# Errors from authentik's server, case-insensitive
{namespace="auth", app="authentik", container="server"} |~ "(?i)error"

# authentik logs JSON: parse it and keep warnings and errors
{namespace="auth", container="server"} | json | level =~ "warning|error"

# Flux controllers' reconciliation errors (they log JSON with a "level" field)
{namespace="flux-system"} | json | level="error"

# One pod's previous run, e.g. after a crash: pick the time range around the restart
{namespace="observability", pod="loki-0"}

# Lines per namespace over time (a metric query: use a time-series panel)
sum by (namespace) (count_over_time({namespace=~".+"}[5m]))

# Top 10 noisiest containers in the last hour
topk(10, sum by (namespace, container) (bytes_over_time({namespace=~".+"}[1h])))

# Postgres errors in every CNPG cluster (CNPG logs JSON; the message is under .record)
{container="postgres"} | json | record_error_severity =~ "ERROR|FATAL|PANIC"
```

## Monitoring Loki and Alloy

Both charts' `ServiceMonitor`s are on, scraped every 30s: job `observability/loki` (the chart's relabelling adds the namespace) and job `alloy`.

**Cluster Health** has a **Logs** row: Loki up or down, Alloy pods unavailable, lines dropped in the range, Loki's volume usage, and lines shipped per Alloy pod.

### Alerts

`loki/app/prometheusrule.yaml` and `alloy/app/prometheusrule.yaml`:

| Alert | Fires when | For | Severity |
| --- | --- | --- | --- |
| `LokiDown` | Prometheus can't scrape Loki, or Loki's target is gone | 10m | warning |
| `LokiIngestionStopped` | Loki received no lines in the last 10 minutes | 15m | warning |
| `LokiRequestErrors` | over 5% of requests on a route fail with a 5xx | 15m | warning |
| `LokiRetentionNotApplied` | the compactor hasn't applied retention for 3 hours | 15m | warning |
| `AlloyNotShipping` | an Alloy pod sent no lines in the last 15 minutes | 15m | warning |
| `AlloyDroppingLogs` | an Alloy pod dropped lines in the last 10 minutes | 5m | warning |
| `AlloyComponentUnhealthy` | a component in an Alloy pod's pipeline is unhealthy | 10m | warning |

The cluster always logs (the kube-apiserver static pod on every node alone does), so silence means the pipeline is broken, not that nothing happened. kube-prometheus-stack's own rules cover the rest: `KubeDaemonSetNotScheduled` and `KubeDaemonSetRolloutStuck` (an Alloy pod missing), `TargetDown`, and `KubePersistentVolumeFillingUp` (Loki's volume).

What to do:

- **`LokiDown`**: `kubectl -n observability get pod loki-0 -o wide`, then its events and logs. A pod stuck `Pending` or `ContainerCreating` is usually its Longhorn volume: see [Longhorn → Monitoring](/kubernetes/storage-longhorn#monitoring).
- **`LokiIngestionStopped`** with Loki up: every Alloy is failing. Check `kubectl -n observability logs ds/alloy -c alloy` for `loki.write` errors, and the push endpoint: `kubectl -n observability run curl --rm -it --image=curlimages/curl -- curl -s http://loki:3100/ready`.
- **`AlloyNotShipping`**: one node's pod. Its logs and its UI (port-forward to that pod, port 12345) show which component is unhealthy. A discovery error usually means it can't reach the API server.
- **`AlloyDroppingLogs`**: the `reason` label says why. `rate_limited` and `stream_limited`: raise Loki's `ingestion_rate_mb` / `ingestion_burst_size_mb` (`loki.limits_config`), or find the noisy container with the top-10 query above. `line_too_long` or `too_far_behind`: one app is misbehaving. Otherwise Loki was unreachable for longer than Alloy's retries.
- **`LokiRequestErrors`**: Loki's logs, `{namespace="observability", pod="loki-0"} |= "level=error"`, if Loki can still answer that query. Otherwise `kubectl logs`.
- **`LokiRetentionNotApplied`**: `{namespace="observability", pod="loki-0"} |= "compactor"`. If the volume is full, the compactor can't write its marker files: grow the volume first.

## Checks

```sh
flux get kustomizations -n observability loki alloy   # both Ready
kubectl -n observability get pods -l app.kubernetes.io/name=alloy -o wide   # one per node, Running
kubectl -n observability get pod loki-0                # Running, 1/1
kubectl -n observability get pvc storage-loki-0        # Bound, 20Gi
```

In Grafana's Explore, with data source **Loki**:

- `{namespace="auth"}` returns authentik's logs.
- `count by (namespace) (count_over_time({namespace=~".+"}[1h]))` returns a series for every namespace.
- `count by (node) (count_over_time({namespace=~".+"}[5m]))` returns all three nodes.

In Prometheus's `/targets`, `observability/loki` and `alloy` (three targets) are up.

To check that logs survive a restart: note a line from a few minutes ago, `kubectl -n observability delete pod loki-0`, wait for it to be Ready, and query it again.
