---
sidebar_position: 1.5
sidebar_label: Observability for a new app
---

# Observability for a new app

What to set up when a new app lands in `kubernetes/apps/<ns>/<app>/`, so it has metrics, a dashboard, alerts and logs like everything else. In short:

| | What to do | Needed? |
| --- | --- | --- |
| [Logs](#logs) | Nothing: Alloy picks up every pod. Check them in Grafana | Always, it's automatic |
| [Metrics](#metrics) | Turn on the chart's `ServiceMonitor`, or write one | If the app exports Prometheus metrics |
| [Dependencies](#dependencies) | `dependsOn` `prometheus-operator-crds` in `ks.yaml` | If it ships a monitor or a rule |
| [Dashboard](#dashboard) | Dashboard JSON next to the app, as a labelled ConfigMap | If there are metrics worth a page |
| [Alerts](#alerts) | A `PrometheusRule` next to the app | For anything that should wake me or nag me |
| [Database](#database) | A `PodMonitor` for its CNPG `Cluster` | If it has a database |
| [Cluster Health](#cluster-health) | A row on the Cluster Health dashboard | For apps the cluster depends on |
| [Docs](#docs) | A page, or a section, saying what's scraped, the dashboard and the alerts | Whenever any of the above is done |

Without any of this the app is still watched in general terms: kube-state-metrics and cAdvisor give every pod's restarts, readiness, CPU and memory, and kube-prometheus-stack's default rules alert on crash loops (`KubePodCrashLooping`), pods not ready (`KubePodNotReady`), stuck rollouts, full PVCs and so on.

## Logs

Nothing to configure: Alloy ships the stdout and stderr of every container on every node to Loki ([Logs](/kubernetes/observability/logs)), labelled with `namespace`, `pod`, `container`, `app` and `node`. `app` comes from the pod's `app.kubernetes.io/name` label (or `app`, or `k8s-app`), which almost every chart sets, so `{app="<app>"}` usually works.

What helps:

- **Log to stdout/stderr, not to files in the container.** Alloy reads only what the kubelet writes to `/var/log/pods`. If the app insists on a file, look for a chart value to log to stdout, or add a sidecar that `tail -F`s the file.
- **JSON or logfmt, if the app can.** Then `| json` or `| logfmt` turns every field into a label at query time, e.g. `{app="<app>"} | json | level="error"`. Look for a `log.format` / `logging.json` chart value.
- **Info level, not debug.** Loki keeps everything for 7 days on a 20Gi volume, and debug logs from one chatty app can fill it.

Check: in Grafana's **Explore** with data source **Loki**, `{namespace="<ns>"}` returns the app's lines, or open **Pod Logs** (`/d/pod-logs`) and pick the namespace.

## Metrics

Prometheus selects **every** `ServiceMonitor`, `PodMonitor`, `Probe`, `ScrapeConfig` and `PrometheusRule` in the cluster, in any namespace and with any labels (the `*SelectorNilUsesHelmValues: false` values). An app needs no `release:` label.

1. If the app's chart has a `serviceMonitor.enabled` (or `metrics.serviceMonitor.enabled`, `podMonitor.enabled`…) value, turn it on in the chart values. Some charts also need the metrics endpoint itself turned on (`metrics.enabled`). Otherwise add a `ServiceMonitor` next to the app:

   ```yaml
   ---
   # yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/monitoring.coreos.com/servicemonitor_v1.json
   apiVersion: monitoring.coreos.com/v1
   kind: ServiceMonitor
   metadata:
     name: <app>
   spec:
     selector:
       matchLabels:
         app.kubernetes.io/name: <app>   # the labels on the app's Service
     endpoints:
       - port: metrics                   # the Service's port *name*
         interval: 30s
   ```

   Use `interval: 30s` unless there's a reason not to: Prometheus is short on memory, and many charts default to 10s or 15s.

2. Check it on Prometheus's targets page (`https://prometheus.<domain>/targets`): the new job should be `UP`. Note the `job` label, since the dashboard and the alerts will select on it.
3. If the app exports thousands of series it doesn't need, trim them with `metricRelabelings` (a `keep` regex on `__name__`), as for Cilium's Envoy ([Networking and certificates](/kubernetes/observability/networking#cilium-and-hubble)). `topk(10, count by (__name__) ({job="<job>"}))` shows the biggest.

## Dependencies

An app that ships a `ServiceMonitor`, `PodMonitor` or `PrometheusRule` needs the CRDs before Flux can apply it. Its `ks.yaml` `dependsOn` the CRDs, **not** kube-prometheus-stack ([why](/kubernetes/observability/intro#the-crds-come-first)):

```yaml
  dependsOn:
    - name: prometheus-operator-crds
      namespace: observability
```

## Dashboard

The chart's own dashboard is the first place to look: many charts have a `grafanaDashboard.enabled` or `dashboards.enabled` value that creates the ConfigMaps below. Then only the label and annotation need setting. Otherwise take one from the project's repository or grafana.com, or build one in Grafana.

Every dashboard comes from Git, through Grafana's dashboard sidecar. The sidecar watches **every namespace** for ConfigMaps labelled `grafana_dashboard: "1"`, and puts each one in the folder named by its `grafana_folder` annotation. Dashboards edited in the UI can't be saved over a provisioned one (`allowUiUpdates: false`): export the JSON and commit it instead.

1. Put the dashboard JSON next to the app, e.g. `kubernetes/apps/<ns>/<app>/app/dashboards/<name>.json`. Export it from Grafana with **Export → Export as JSON**, without "Export for sharing externally", so its datasource is the provisioned `prometheus` UID (`loki` for logs panels). Give it a short, stable `uid`, so links like `/d/<uid>` keep working.
2. Generate a ConfigMap from it in the app's `kustomization.yaml`:

   ```yaml
   configMapGenerator:
     - name: <app>-dashboards
       files:
         - ./dashboards/<name>.json
       options:
         disableNameSuffixHash: true
         labels:
           grafana_dashboard: "1"
         annotations:
           grafana_folder: <Folder>
           # Dashboard JSON is full of ${var}; without this Flux's postBuild
           # substitution blanks them out.
           kustomize.toolkit.fluxcd.io/substitute: disabled
   ```

3. Commit and reconcile. The sidecar picks it up within a few seconds, with no Grafana restart.

Folders in use: **Kubernetes** (the cluster itself: nodes, Flux, Longhorn, Cluster Health, Pod Logs), **Network** (Cilium, Hubble, cert-manager), **Databases** (CNPG), **Auth** (authentik). Add one when an app doesn't fit.

**Logs on the dashboard.** A table with `namespace` and `pod` columns can link each pod to its logs: see [From a metrics dashboard to logs](/kubernetes/observability/logs#from-a-metrics-dashboard-to-logs). A logs panel on the Loki data source (`{namespace="<ns>", app="<app>"} |~ "(?i)error"`) below the metrics is often the quickest way to see why a graph jumped.

## Alerts

Alerting rules go in a `PrometheusRule` next to the app (`app/prometheusrule.yaml`, listed in its `kustomization.yaml`). Alertmanager routes on `severity` alone, so no receiver config is needed ([Alerting](/kubernetes/observability/alerting)):

| `severity` | Goes to | Use it for |
| --- | --- | --- |
| `critical` | Pushover, high priority (sound during quiet hours) | The app, or something depending on it, is down for users now |
| `warning` | Pushover, normal priority | Needs a look today: degraded, failing in the background, about to break |
| `info` | Nowhere | Context for other alerts, visible in Alertmanager only |

A template, following the other rules in the repo:

```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/monitoring.coreos.com/prometheusrule_v1.json
# <What these alerts watch, and from which metrics (job "<job>").>
# Docs: docs/docs/kubernetes/<page>.md#alerts
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: <app>
  annotations:
    # $labels and $value are Prometheus templating, not Flux variables.
    kustomize.toolkit.fluxcd.io/substitute: disabled
spec:
  groups:
    - name: <app>
      rules:
        - alert: <App>Down
          expr: |
            sum(kube_deployment_status_replicas_available{namespace="<ns>", deployment="<app>"}) == 0
          for: 10m
          labels:
            severity: critical
          annotations:
            summary: "<App> has no available pods"
            description: >-
              What is broken for whom, and the first thing to check.
              {{ $labels.namespace }} and {{ $value }} work here.
```

Guidelines:

- **Alert on symptoms**: no available pods, errors returned, work not getting done (a queue that only grows, a sync that's stale). Generic pod problems are already covered by the default rules (above), so don't repeat `KubePodCrashLooping` per app.
- **Always set `for`**, at least 5m, and 10m or more for anything a Talos upgrade can cause (it reboots one node at a time).
- **Group by the labels a human needs** (`namespace`, `pod`, `job`), so the notification says where, and grouping in Alertmanager (`alertname`, `namespace`) stays useful.
- **The `kustomize.toolkit.fluxcd.io/substitute: disabled` annotation is required** if the app's `ks.yaml` has `postBuild.substituteFrom`: otherwise Flux replaces `$labels` and `$value` with empty strings.
- **Every alert gets a "what to do" in the docs** (below).
- **Missing metrics are silent.** A rule on a metric that disappears (the target is down, a metric was renamed) never fires. `TargetDown` covers an unreachable target. For an alert that matters, add an `absent(...)` rule too, as `LokiDown` does.

Test it: Prometheus's `/alerts` page lists the rule (with its state), and `/rules` shows the expression evaluating. To see a notification end to end, follow [Sending a test alert](/kubernetes/observability/alerting#sending-a-test-alert).

To change or turn off a kube-prometheus-stack default rule for an app instead, see [Turning off a default rule](/kubernetes/observability/alerting#turning-off-a-default-rule).

## Database

Every CNPG `Cluster` gets its own `PodMonitor`, next to the Cluster. Copy `kubernetes/apps/auth/authentik/db/podmonitor.yaml`, change the name and the `cnpg.io/cluster` selector, and add `prometheus-operator-crds` to the database's `ks.yaml` `dependsOn`. The CNPG dashboard and the backup and WAL alerts then cover it with no other change ([Databases](/kubernetes/observability/intro#databases)).

## Cluster Health

Apps the rest of the cluster depends on (authentication, storage, networking, DNS…) get a row on **Cluster Health** (`kube-prometheus-stack/app/dashboards/cluster-health.json`): a few stats that count problems, so green means zero, and one or two graphs. Add a link to the app's own dashboard in the dashboard's `links`. Apps that only serve people can skip this: their own dashboard and alerts are enough.

## Docs

Each app's docs page (or the Observability page about it) says:

- what is scraped: Prometheus `job`, port, the chart values that turn it on;
- the dashboard: name, `/d/<uid>`, folder, and what each row shows;
- the alerts: a table of alert, fires when, `for`, severity, and **what to do** for each;
- anything not collected, and why.

Link the page from the scrape-target table in the [Overview](/kubernetes/observability/intro#what-runs-where).
