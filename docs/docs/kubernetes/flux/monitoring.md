---
sidebar_position: 3
sidebar_label: Monitoring
---

# Monitoring Flux

Prometheus scrapes both the Flux Operator and the Flux controllers. Grafana shows the result on a **Flux** dashboard and in a Flux row on **Cluster Health**, and an alert fires when a Flux resource stays not ready ([#189](https://github.com/lorenzorapetti/homelab/issues/189)). The alert goes through Alertmanager to Pushover like every other alert ([Alerting](/kubernetes/observability/alerting)). There is no notification-controller `Provider` or `Alert`.

## Where the metrics come from

| Source | Metrics | Scraped by | Defined in |
| --- | --- | --- | --- |
| Flux Operator, Service `flux-operator:8080` | `flux_resource_info`, `flux_instance_info`, `flux_operator_info`, `controller_runtime_*` | `ServiceMonitor` `flux-operator`, from the operator chart (`serviceMonitor.create`) | `flux-operator/app/helmrelease.yaml` |
| The four Flux controllers, port `http-prom` (8080) | `gotk_reconcile_duration_seconds`, `controller_runtime_reconcile_*`, `workqueue_*` | `PodMonitor` `flux-system`, copied from [flux2-monitoring-example](https://github.com/fluxcd/flux2-monitoring-example) | `flux-monitoring/app/podmonitor.yaml` |

**Resource state comes from the operator.** `flux_resource_info` has one series per Flux object (Kustomizations, HelmReleases, GitRepository/OCIRepository/HelmRepository, HelmCharts…) with labels `kind`, `name`, `exported_namespace`, `ready` (`True`, `False` or `Unknown` while reconciling), `reason`, `suspended`, `revision`, and per kind `source_name`, `path`, `url`, `ref` ([Flux Operator monitoring](https://fluxoperator.dev/docs/instance/monitoring/)). The FluxInstance itself is in `flux_instance_info`. The operator refreshes them with its FluxReport, every `reporting.interval`. The default is 5m; the docs recommend **30s** when Prometheus reads them, which is what's set.

The community dashboards (e.g. Grafana 16714) use `gotk_resource_info` instead, which kube-state-metrics builds from a custom-resource config. The labels differ, so neither those dashboards nor their queries work here.

**The controllers export their own reconcile metrics**, but not resource state. `gotk_reconcile_duration_seconds{kind, name, namespace}` comes out as `exported_namespace` too, because Prometheus keeps the target's `namespace` (`flux-system`) and renames the clashing label. `controller_runtime_reconcile_errors_total{controller}` is per controller only.

The FluxInstance's `allow-scraping` NetworkPolicy already lets every namespace reach port 8080 in `flux-system`, so nothing else is needed for Prometheus to get in.

### The ServiceMonitor CRD and the bootstrap

The chart's ServiceMonitor needs the Prometheus Operator CRDs, which Flux installs only later. Two things keep that from breaking:

- **`flux-operator/ks.yaml` `dependsOn` `prometheus-operator-crds`.** On a fresh cluster, Flux waits for the CRDs before it takes over the release that helmfile installed. On the running cluster it changes nothing.
- **`bootstrap/helmfile/apps.yaml` sets `serviceMonitor.create: false`** for the first install. Helmfile appends that after the values it reads from the HelmRelease. Flux turns the ServiceMonitor on when it takes over. A side effect: `just bootstrap::diff` on the running cluster now also shows the ServiceMonitor being removed. That's expected ([`just bootstrap::apps` after a takeover](/kubernetes/getting-started/bootstrap#just-bootstrapapps-after-a-takeover)).

The PodMonitor, the rule and the dashboard live in their own Kustomization, `flux-monitoring`, which also `dependsOn` the CRDs. They're kept out of `flux-operator/` and `flux-instance/` because every object those apply is never pruned ([Flux must never uninstall itself](/kubernetes/flux/intro#flux-must-never-uninstall-itself)). The `flux-monitoring` Kustomization object gets the same prune annotation from `flux-system/kustomization.yaml`, but the objects it applies prune normally.

```
kubernetes/apps/flux-system/flux-monitoring/
├─ ks.yaml                  # dependsOn prometheus-operator-crds
└─ app/
   ├─ podmonitor.yaml       # the controllers
   ├─ prometheusrule.yaml   # FluxResourceNotReady
   ├─ dashboards/flux.json
   └─ kustomization.yaml    # ConfigMap flux-dashboard, folder Kubernetes
```

## The dashboards

**Flux** (`/d/flux`, folder **Kubernetes**), filterable by Kind and Namespace:

- **Overview**: how many resources, how many not ready and suspended, the FluxInstance's state, the Flux and Flux Operator versions.
- **Flux resources**: one row per resource with Ready, Suspended, the condition reason, the revision it last applied or fetched, and its source, path or URL. Not-ready rows sort first.
- **Reconciliation**: not-ready resources over time, reconcile p99 by kind, reconcile errors by controller.
- **Controllers**: the 15 slowest resources in the time range, and CPU and memory of every pod in `flux-system`.

**Cluster Health** has a **Flux** row: not ready, suspended, reconcile errors and Flux targets down as counters (green means zero), a table of only the resources that are not ready or are suspended, and reconcile p99 by kind. A not-ready resource also shows up in the dashboard's firing alerts once the alert fires.

A resource that is reconciling right now has `ready="Unknown"`, so the not-ready counters can blip to 1 for a moment, usually a HelmRelease upgrading. That's normal; a count that stays is what matters.

## The alert: `FluxResourceNotReady`

`flux-monitoring/app/prometheusrule.yaml`, severity **warning** (Pushover, normal priority):

```promql
label_replace(
  max by (exported_namespace, kind, name) (
    flux_resource_info{ready!="True", suspended="False"}
    or flux_instance_info{ready!="True", suspended="False"}
  ),
  "namespace", "$1", "exported_namespace", "(.*)"
)
```

with `for: 15m`.

- **Both `False` and `Unknown` count**, so a resource stuck progressing (e.g. a HelmRelease waiting on pods that never get ready) alerts too, not only one that has failed. `max by` keeps the series continuous when `ready` flips between the two, so the 15 minutes don't restart.
- **Suspended resources never alert.** The dashboards list them instead.
- **The `namespace` label is the resource's namespace.** The scrape target's would always be `flux-system`. Alertmanager groups by `alertname` and `namespace`, so a bad commit that breaks three Kustomizations in `auth` gives one notification for `auth`.
- **If the operator stops being scraped, the series disappear and the alert resolves.** The chart's `TargetDown` alert covers that case, and Cluster Health shows it as **Flux targets down**.

### When it fires

1. See what failed and why:

   ```sh
   flux get all -n <namespace>
   kubectl -n <namespace> describe <kind> <name>   # Events and the Ready condition's message
   ```

   Or open the Flux dashboard: the **Reason** column says roughly where it broke (`BuildFailed`, `HealthCheckFailed`, `ArtifactFailed`, `UpgradeFailed`, `DependencyNotReady`…).

2. Common causes:
   - **`BuildFailed` on a Kustomization**: kustomize can't build the path. Usually a typo, a missing file in `resources:`, or a missing `patches: []` in a `ks.yaml` ([why](/kubernetes/flux/intro#the-fluxinstance)). Reproduce with `kubectl kustomize <path>`.
   - **`HealthCheckFailed`**: applied, but a health-checked object didn't become ready within `timeout`. Look at the HelmRelease or the pods it names.
   - **A HelmRelease `UpgradeFailed` or `InstallFailed`**: `kubectl -n <namespace> describe helmrelease <name>`, then the pods. After the remediation retries are spent it stays failed until the next change; fix it in Git, then `flux reconcile helmrelease -n <namespace> <name> --force` if it doesn't pick up the change.
   - **`DependencyNotReady`**: the resource is fine, something in its `dependsOn` isn't. Fix that one; this clears on its own.
   - **A source (`GitRepository`, `OCIRepository`, `HelmRepository`) not ready**: auth or network. For `flux-system`, check the deploy key; for charts, the registry.
   - **SOPS decryption errors**: the `sops-age` Secret or the file's recipients.

3. Fix it in Git, push, and reconcile: `flux reconcile kustomization -n <namespace> <name> --with-source`. The alert resolves on the next evaluation once the resource is Ready, and Pushover sends the resolved notification.

To mute it during planned work, silence `alertname="FluxResourceNotReady"` with the namespace in Alertmanager ([Silencing an alert](/kubernetes/observability/alerting#silencing-an-alert)), or `flux suspend` the resource, which also stops the alert.

### Testing it

Break a Kustomization on purpose, e.g. point a throwaway app's `path` at a directory that doesn't exist, commit, and reconcile. Within a minute the Flux dashboard shows it `False`; after 15 minutes `FluxResourceNotReady` fires and Pushover notifies. Revert the commit, reconcile, and the resolved notification follows.

## Checks

```sh
flux get kustomizations -n flux-system   # flux-operator, flux-instance, flux-monitoring Ready
kubectl -n flux-system get servicemonitor,podmonitor,prometheusrule
```

On Prometheus's `/targets` page, `serviceMonitor/flux-system/flux-operator/0` has one target and `podMonitor/flux-system/flux-system/0` has four, all `UP`. In Explore, `count(flux_resource_info)` matches `flux get all -A`, and `count by (kind) (gotk_reconcile_duration_seconds_count)` returns the controllers' kinds.
