---
sidebar_position: 6
sidebar_label: authentik
---

# authentik

authentik's server and worker both export Prometheus metrics on port 9300. The chart's `server.metrics` and `worker.metrics` values (in `auth/authentik/app/helmrelease.yaml`) create a metrics Service and a ServiceMonitor for each, scraped every 30s:

| Prometheus `job` | What it has |
| --- | --- |
| `authentik-server-metrics` | HTTP responses and latency (`django_http_*`, `authentik_main_request_duration_seconds` by destination), flow planning and stage times, policy evaluation, outposts connected, database queries |
| `authentik-worker-metrics` | Background tasks (`authentik_tasks_total`, `_errors_total`, `_retries_total`, `_duration_milliseconds`, queued and in progress), database queries |

The chart's `prometheus.rules` stays off: those are recording rules over 30-second `rate()` windows, which return nothing at a 30-second scrape interval.

## The dashboard

**authentik** (`/d/authentik`, folder **Auth**), from `auth/authentik/app/dashboards/authentik.json` (the chart ships none):

- **Overview**: server and worker pods ready, outposts with no connected instance, HTTP 5xx and task errors over the selected range, and targets down.
- **Requests**: responses by status, p95 latency per destination (`core` is the Django app; `embedded_outpost` is the forward-auth checks for Prometheus, Alertmanager, Longhorn and Glance), and the ten slowest views.
- **Flows and policies**: flow executions per flow (roughly, logins and app authorizations), p95 time per stage and per policy evaluation. Logins are rare here, so these panels are mostly points rather than lines.
- **Worker tasks**: tasks run, errors and retries per task, and the queue. A queue that only grows means the worker is stuck or down.
- **Database**: query latency and rate from server and worker, and connection and query errors. The database's own view is the CloudNativePG dashboard (`authentik-db`).

**Cluster Health** has an **authentik** row: unavailable server and worker pods, disconnected outposts, HTTP 5xx and task errors, with responses by status and p95 latency next to them.

## Alerts

No authentik-specific rules yet. The stack's generic rules cover the failures that matter most: a server or worker that crash-loops or isn't ready (`KubePodCrashLooping`, `KubePodNotReady`, `KubeDeploymentReplicasMismatch`), an unscrapeable target (`TargetDown`), and its database (`CNPGInstanceDown` and the WAL and backup alerts, [Backups: Postgres → Alerts](/kubernetes/backups-postgres#alerts)). When authentik is down, forward-auth apps fail closed: see [Reaching Grafana, Prometheus and Alertmanager](/kubernetes/observability/intro#reaching-grafana-prometheus-and-alertmanager) for the port-forward.

A few task errors are normal: tasks that were running when a pod restarted fail once and are retried. Their tracebacks are under **Admin → Dashboards → System tasks** in authentik.
