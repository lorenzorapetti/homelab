---
sidebar_position: 1
sidebar_label: Overview
---

# Observability

Metrics, dashboards and alerts come from [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack), in the `observability` namespace (step 8 of the [migration](/kubernetes/migration)). It gives node and pod health out of the box. [Control-plane metrics](/kubernetes/observability/control-plane-metrics) adds etcd, the scheduler and the controller-manager. [Alerting](/kubernetes/observability/alerting) sends alerts to Pushover. [Networking and certificates](/kubernetes/observability/networking) covers Cilium, Hubble, the Gateway's Envoy and cert-manager, and [authentik](/kubernetes/observability/authentik) authentik's server and worker. Later pages will add logs.

## What runs where

Everything is in `kubernetes/apps/observability/`, as three Flux Kustomizations:

| Kustomization | Path | What it deploys | Depends on |
| --- | --- | --- | --- |
| `prometheus-operator-crds` | `prometheus-operator-crds/app/` | The Prometheus Operator CRDs, chart `33.0.2` (operator `v0.95.2`) | — |
| `observability-db` | `observability-db/app/` | CNPG `Cluster` `observability-db`, its `ObjectStore` `observability-r2`, `ScheduledBackup` `observability-db-nightly` and `PodMonitor` | `longhorn`, `plugin-barman-cloud`, `prometheus-operator-crds` |
| `kube-prometheus-stack` | `kube-prometheus-stack/app/` | The `HelmRelease`, chart `93.5.0` from `oci://ghcr.io/prometheus-community/charts` | `prometheus-operator-crds`, `observability-db`, `longhorn`, `gateway`, `authentik` |

### The CRDs come first

The CRDs (`ServiceMonitor`, `PodMonitor`, `PrometheusRule`, `Prometheus`…) are a release of their own, with no dependencies, and kube-prometheus-stack has `crds.enabled: false`. Apps that ship monitors depend only on the CRDs, not on the whole stack. Without this there would be a cycle: kube-prometheus-stack waits for `observability-db`, which waits for the CNPG operator, which needs the `PodMonitor` CRD for its own metrics.

- The CRDs carry `helm.sh/resource-policy: keep`, so uninstalling the release, or a Flux prune, never deletes them, or every monitor and rule with them.
- `prometheus-operator-crds` and kube-prometheus-stack must ship the same operator version. Upgrade them in one commit, CRDs first. The chart versions differ: 33.0.2 and 93.5.0 both carry `v0.95.2`. Check `appVersion` with `helm show chart`.
- History: on 2026-11-20 the first install of kube-prometheus-stack created the CRDs. The `prometheus-operator-crds` release then adopted them (helm-controller takes ownership of existing objects by default). Helm never deletes CRDs it installed from a chart's `crds/` directory, so turning `crds.enabled` off removed nothing.

The chart installs:

| Component | Kind | Storage | Notes |
| --- | --- | --- | --- |
| Prometheus Operator (`v0.95.2`) | Deployment | — | Turns `Prometheus`, `Alertmanager`, `ServiceMonitor`, `PodMonitor`, `PrometheusRule`… into running config |
| Prometheus | StatefulSet (1 replica) | 20Gi Longhorn PVC | 14 days or 15 GB of data, whichever comes first |
| Alertmanager | StatefulSet (1 replica) | 1Gi Longhorn PVC | `critical` and `warning` alerts to Pushover, `Watchdog` to healthchecks.io ([Alerting](/kubernetes/observability/alerting)) |
| Grafana (chart `14.5.0`, Grafana 13.3) | Deployment | none: state is in Postgres | Plus the dashboard and datasource sidecars |
| kube-state-metrics | Deployment | — | Object state: pod start time, readiness, restarts… |
| node-exporter | DaemonSet | — | Host metrics on every node. Needs `hostNetwork`/`hostPID`, so the namespace is labelled `pod-security.kubernetes.io/enforce: privileged` (Talos applies `baseline` everywhere else, as for `longhorn-system`) |

What Prometheus scrapes:

| Target | Status |
| --- | --- |
| node-exporter, kubelet and cAdvisor, kube-state-metrics, apiserver, CoreDNS | On |
| The stack itself: Prometheus, Alertmanager, the operator, Grafana | On |
| CloudNativePG: the operator (chart `PodMonitor`) and every `Cluster`'s instances (one `PodMonitor` per Cluster) | On, see [Databases](#databases) |
| Flux: the Flux Operator (chart `ServiceMonitor`) and the four controllers (`PodMonitor`) | On, see [Monitoring Flux](/kubernetes/flux/monitoring) |
| Longhorn: every `longhorn-manager` (chart `ServiceMonitor`) | On, see [Longhorn → Monitoring](/kubernetes/storage-longhorn#monitoring) |
| Cilium: agent, operator, Envoy and Hubble (chart `ServiceMonitor`s) | On, see [Networking and certificates](/kubernetes/observability/networking#cilium-and-hubble) |
| cert-manager: controller, cainjector, webhook (chart `ServiceMonitor`) | On, see [Networking and certificates](/kubernetes/observability/networking#cert-manager) |
| ExternalDNS (chart `ServiceMonitor`) | On, see [DNS: ExternalDNS → Alerts](/kubernetes/dns-externaldns#alerts) |
| authentik: server and worker (chart `ServiceMonitor`s) | On, see [authentik](/kubernetes/observability/authentik) |
| kube-proxy | **Off for good.** Cilium replaces kube-proxy, so there is nothing to scrape |
| kube-controller-manager, kube-scheduler, etcd | On, on the three node IPs. Needs the Talos patch `talos/control-plane/10-metrics.yaml`, see [Control-plane metrics](/kubernetes/observability/control-plane-metrics) |

The settings are all chart values in `kube-prometheus-stack/app/helmrelease.yaml`. The only env var is Grafana's database password, which CNPG generates.

Resource requests are kept small, because nodes have ~3.8 GB allocatable and are already more than half full: Prometheus asks for 512Mi (limit 1.5Gi), Grafana 192Mi, and every other component 64Mi or less.

## Reaching Grafana, Prometheus and Alertmanager

All three are routes on the [Shared Gateway](/kubernetes/getting-started/bootstrap#the-shared-gateway), so they use its wildcard certificate. ExternalDNS publishes their names to Home DNS only ([ADR 0001](https://github.com/lorenzorapetti/homelab/blob/main/docs/adr/0001-app-names-only-in-home-dns.md)), so they work from the LAN and the tailnet, not from the internet.

| App | URL | Route (chart values) | Login |
| --- | --- | --- | --- |
| Grafana | `https://grafana.<domain>` | `grafana.route.main` | Authentik OIDC (Grafana's own), `authentik Admins` only, plus a break-glass local admin ([Grafana login](/kubernetes/observability/grafana-login)) |
| Prometheus | `https://prometheus.<domain>` | `prometheus.route.main` | Authentik forward auth, `authentik Admins` only |
| Alertmanager | `https://alertmanager.<domain>` | `alertmanager.route.main` | Authentik forward auth, `authentik Admins` only |

The chart generates the routes itself (HTTPRoutes `kube-prometheus-stack-{grafana,prometheus,alertmanager}`), so there is no `httproute.yaml`.

### Authentik forward auth

Prometheus and Alertmanager have no login of their own. They are the first apps behind Authentik through the Gateway API `ExternalAuth` filter ([plan](/kubernetes/migration#authentik-forward-auth-with-cilium-gateway)). Each of their routes has:

- **An `ExternalAuth` filter on `/`.** Before forwarding a request, Cilium's Envoy asks Authentik's embedded outpost at `authentik-server.auth:80/outpost.goauthentik.io/auth/envoy`, passing the `cookie` header. A `2xx` lets the request through, with `x-authentik-username`, `-groups` and `-email` added. Anything else, normally a redirect to the login page, goes back to the browser.
- **A rule for `/outpost.goauthentik.io`** that sends the login start and callback on the app's own host straight to `authentik-server`, which hands them to the embedded outpost.

Both point across namespaces, which ReferenceGrant `authentik-forward-auth` in `auth` allows for HTTPRoutes in `observability` and `longhorn-system`. The Longhorn UI uses the same setup, in its own `httproute.yaml` ([The UI](/kubernetes/storage-longhorn#the-ui)).

On the Authentik side, everything comes from a blueprint in Git: `kubernetes/apps/auth/authentik/app/blueprints/forward-auth.yaml`, mounted into the worker through the chart's `blueprints.configMaps`. For each app it creates:

- a Proxy provider in `forward_single` mode, with the app's URL as external host and the implicit-consent authorization flow;
- an Application, with a policy binding to the `authentik Admins` group;
- an entry in the embedded outpost's provider list.

The worker re-applies the blueprint when the ConfigMap changes. Under **Customization → Blueprints** in Authentik, "Forward auth apps" should show as *successful*.

The outpost's provider list in the blueprint **replaces** the outpost's providers. A provider added to the embedded outpost only in the UI is dropped on the next apply.

To put another app behind forward auth:

1. Add its provider, application, policy binding and outpost entry to `forward-auth.yaml`.
2. Add its namespace to the `from` list of `referencegrant.yaml` (`kubernetes/apps/auth/authentik/app/`).
3. Give its HTTPRoute the same `ExternalAuth` filter and `/outpost.goauthentik.io` rule as here (the `&forwardAuth` and `&outpostRules` anchors in `kube-prometheus-stack/app/helmrelease.yaml`), and make its `ks.yaml` `dependsOn` `authentik`.

### Grafana's login

Grafana logs in against Authentik with native OIDC, not forward auth: see [Grafana login](/kubernetes/observability/grafana-login) for the provider and application, the group-to-role mapping, and the break-glass local `admin`.

If Authentik is down, Prometheus and Alertmanager fail closed. Port-forward to reach them anyway:

```sh
kubectl port-forward -n observability svc/kube-prometheus-stack-prometheus 9090
# http://localhost:9090/targets
```

## Dashboards

The chart ships the usual dashboards ("Node Exporter / Nodes", "Kubernetes / Compute Resources / Pod", CoreDNS, etcd, Controller Manager, Scheduler, Prometheus, Alertmanager, Grafana…), in the **Kubernetes** folder.

Every other dashboard comes from Git, through Grafana's dashboard sidecar. The sidecar watches **every namespace** for ConfigMaps labelled `grafana_dashboard: "1"`, and puts each one in the folder named by its `grafana_folder` annotation. Dashboards edited in the UI can't be saved over a provisioned one (`allowUiUpdates: false`): export the JSON and commit it instead.

### Adding a dashboard for an app

1. Put the dashboard JSON next to the app, e.g. `kubernetes/apps/<ns>/<app>/app/dashboards/<name>.json`. Export it from Grafana with **Export → Export as JSON**, without "Export for sharing externally", so its datasource is the provisioned `prometheus` UID.
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

A chart that ships its own dashboards usually has a value that creates these ConfigMaps (often `grafanaDashboard.enabled` or `dashboards.enabled`); then only the label and annotation need setting.

## Metrics and rules for a new app

Prometheus selects **every** `ServiceMonitor`, `PodMonitor`, `Probe`, `ScrapeConfig` and `PrometheusRule` in the cluster, in any namespace and with any labels (the `*SelectorNilUsesHelmValues: false` values). An app needs no `release:` label.

1. If the app's chart has a `serviceMonitor.enabled` (or `metrics.serviceMonitor.enabled`, `podMonitor.enabled`…) value, turn it on in the chart values. Otherwise add a `ServiceMonitor` next to the app:

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

2. The app's `ks.yaml` must `dependsOn` the CRDs (`name: prometheus-operator-crds`, `namespace: observability`), not kube-prometheus-stack ([why](#the-crds-come-first)).
3. Alerting rules go in a `PrometheusRule` next to the app, in the same way.
4. Check it on Prometheus's targets page (above): the new job should be `UP`.

## Databases

Every CNPG Postgres instance exports metrics on its `metrics` port (9187).

- **One `PodMonitor` per Cluster**, next to the Cluster: `observability-db/app/podmonitor.yaml` and `kubernetes/apps/auth/authentik/db/podmonitor.yaml`. It selects `cnpg.io/cluster: <name>` and `cnpg.io/podRole: instance`. CNPG deprecated its own `spec.monitoring.enablePodMonitor` in favour of writing the PodMonitor yourself.
- **A new app's database** copies that file, changes the name, and adds `prometheus-operator-crds` to its `ks.yaml` `dependsOn`.
- **The operator** gets its PodMonitor from its chart (`monitoring.podMonitorEnabled`).
- **The dashboard:** CNPG's cluster dashboard, in Grafana's **Databases** folder. It's a copy of the chart's dashboard in `cnpg-system/cloudnative-pg/app/dashboards/`, changed to read the barman-cloud plugin's backup metrics, and the chart's own copy is turned off (`monitoring.grafanaDashboard.create: false`). It covers every Cluster, picked with its `cluster` variable, including WAL archiving and backup status.
- **Alerts** for every Cluster (instance down, WAL archiving, failed or stale base backups) are in `cnpg-system/cloudnative-pg/app/prometheusrule.yaml`. What each one means and what to do: [Backups: Postgres → Alerts](/kubernetes/backups-postgres#alerts).

Longhorn's metrics, dashboard and alerts are on the [Longhorn page](/kubernetes/storage-longhorn#monitoring).

## Grafana's database

Grafana keeps users, folders, preferences and alerting state in Postgres, not in a SQLite file on a PVC. The database is `grafana`, owned by role `grafana`, in the CNPG `Cluster` `observability-db`:

- One instance, Postgres 18.7, 5Gi on Longhorn, as for `authentik-db`.
- **One Cluster for the whole namespace.** Unlike other apps, which each have their own Cluster ([ADR 0002](https://github.com/lorenzorapetti/homelab/blob/main/docs/adr/0002-cloudnativepg-fresh-start.md)), the observability apps share this one, because they are upgraded and restored as one stack. `initdb` created `grafana`; later databases get their own role (`spec.managed.roles`) and a `Database` object.
- Grafana connects to Service `observability-db-rw` over TLS (`ssl_mode: require`). CNPG generated the password into Secret `observability-db-app`, and Grafana reads it as `GF_DATABASE_PASSWORD`.
- Because Grafana has no state of its own, its pod can move between nodes freely.

### Backups

The Barman Cloud plugin archives WAL continuously to `s3://<bucket>/observability/observability-db/` on R2, and takes a base backup every night at 03:15 UTC, with a 30-day recovery window ([ADR 0003](https://github.com/lorenzorapetti/homelab/blob/main/docs/adr/0003-backups-to-r2.md)). Checking, testing and restoring work exactly as for `authentik-db` ([Backups: Postgres](/kubernetes/backups-postgres)), with these names:

| | `authentik-db` | `observability-db` |
| --- | --- | --- |
| Namespace | `auth` | `observability` |
| `ObjectStore` | `authentik-r2` | `observability-r2` |
| `ScheduledBackup` | `authentik-db-nightly` | `observability-db-nightly` |
| Path on R2 | `authentik/` | `observability/` |

Quick check:

```sh
kubectl get cluster observability-db -n observability -o json \
  | jq -r '.status.conditions[] | "\(.type)=\(.status)  \(.message)"'
kubectl get backups.postgresql.cnpg.io -n observability
```

Prometheus and Alertmanager data are **not** backed up. They live on Longhorn volumes, which survive pod restarts and node moves, but not the loss of the cluster. Losing up to 14 days of metrics is acceptable.

## Checks

After a change, these should all hold:

```sh
flux get kustomizations -n observability     # all three Ready
flux get helmreleases -n observability       # prometheus-operator-crds and kube-prometheus-stack Ready
kubectl get pods -n observability            # all Running and Ready
kubectl get pvc -n observability             # Prometheus, Alertmanager and the database Bound
```

In Prometheus (`/targets`), no target should be down. In a private window, `https://prometheus.<domain>` and `https://alertmanager.<domain>` should send you to Authentik's login and back, and a user outside `authentik Admins` should be refused. In Grafana's Explore, `kube_pod_start_time`, `kube_pod_status_ready{condition="true"}` and `kube_pod_container_status_restarts_total` should return a series per pod, and "Node Exporter / Nodes" should list all three nodes.
