---
sidebar_position: 5
sidebar_label: Networking and certificates
---

# Networking and certificates

Metrics, dashboards and alerts for Cilium (agent, operator, Hubble and the Envoy behind the [Shared Gateway](/kubernetes/getting-started/bootstrap#the-shared-gateway)) and cert-manager. ExternalDNS's alerts are on its own page ([DNS: ExternalDNS → Alerts](/kubernetes/dns-externaldns#alerts)), and authentik's dashboard on [authentik](/kubernetes/observability/authentik). All of them also have a row on **Cluster Health**.

## Cilium and Hubble

### What is scraped

Everything comes from the Cilium chart's values in `kube-system/cilium/app/helmrelease.yaml`, scraped every 30s (the chart's default is 10s; Prometheus is short on memory).

| Target (Prometheus `job`) | Port | Chart values | What it has |
| --- | --- | --- | --- |
| `cilium-agent` | 9962 on each node | `prometheus.enabled`, `prometheus.serviceMonitor` | Datapath drops and forwards, BPF map pressure, endpoints, controllers, node-to-node health |
| `cilium-operator` | 9963 | `operator.prometheus.serviceMonitor` | The operator's own work (IPAM, identities) |
| `cilium-envoy` | 9964 on each node | `envoy.prometheus.serviceMonitor` | The Gateway's listeners and one upstream cluster per backend Service |
| `hubble-metrics` | 9965 on each node | `hubble.metrics.enabled`, `hubble.metrics.serviceMonitor` | Flows, drops, TCP flags, DNS, ICMP and L7 HTTP, by workload and namespace |

The agent and Envoy run with `hostNetwork`, so Prometheus scrapes them on the node IPs. Nothing in the cluster restricts that (no CiliumNetworkPolicies yet).

**Labels.** Both the agent and Hubble ServiceMonitors add `node` (the chart's default relabeling, repeated because setting `relabelings` replaces it) and a constant `cluster="homelab"`. Hubble's namespace dashboards filter on `cluster`, and show nothing without it.

**Envoy is trimmed.** Each Envoy exports about 4,000 series, mostly about its own internals. A `metricRelabelings` keep-list leaves the downstream request counters and latency (`envoy_http_downstream_rq_*`), the upstream ones per backend (`envoy_cluster_upstream_rq_*`, connection failures, timeouts), cluster membership and a few server gauges. The Gateway's listeners are `envoy_http_conn_manager_prefix="listener-secure"` (443) and `"listener-insecure"` (80, the redirect); the backends are `envoy_cluster_name="kube-system/cilium-gateway-main/<namespace>_<service>_<port>"`.

**Hubble metrics** are the flow metrics the agents compute from what Hubble sees:

```text
dns:query;ignoreAAAA   drop   tcp   flow   icmp    each with
  sourceContext=workload-name|reserved-identity;destinationContext=workload-name|reserved-identity;
  labelsContext=source_namespace,destination_namespace
httpV2:labelsContext=source_namespace,source_workload,destination_namespace,destination_workload,traffic_direction
```

`source` and `destination` are the workload name, or a reserved identity (`world`, `host`, `remote-node`…) for traffic that has none. `httpV2` only sees L7 flows, which here means the Gateway's HTTP traffic that Envoy reports to Hubble. `port-distribution` is left out because it adds a series per port.

**Bootstrap.** `bootstrap/helmfile/apps.yaml` turns all four ServiceMonitors off for the first install: the chart fails without the `monitoring.coreos.com/v1` CRDs, which don't exist yet. Flux turns them back on when it adopts the release, and the `cilium` Kustomization `dependsOn` `prometheus-operator-crds` so that it only does once they exist.

### Dashboards

The chart's own dashboards, in Grafana's **Network** folder (`dashboards.enabled`, `operator.dashboards.enabled`, `hubble.metrics.dashboards.enabled`, each with the `grafana_folder: Network` annotation):

| Dashboard | Use it for |
| --- | --- |
| **Cilium Metrics** (`/d/vtuWtdumz`) | One agent at a time: API and BPF latency, drops and forwards, endpoints, controllers, conntrack, Kubernetes events |
| **Cilium Operator** (`/d/1GC0TT4Wz`) | The operator's CPU, memory and IPAM |
| **Hubble / Network Overview (Namespace)** (`/d/nlsO8tYVz`) | Flows, drops (with their reason) and TCP flags between namespaces and workloads: start here when something can't connect |
| **Hubble / DNS Overview (Namespace)** (`/d/_f0DUpY4k`) | DNS queries, missing answers and error codes, by workload |
| **Hubble L7 HTTP Metrics by Workload** (`/d/3g264CZVz`) | Requests, errors and latency of the Gateway's HTTP traffic per backend workload |
| **Hubble Metrics and Monitoring** (`/d/5HftnJAWz`) | The older all-in-one Hubble dashboard, per agent; its port-distribution panel stays empty |

**Cluster Health** has a **Cilium and the Gateway** row: Cilium pods unavailable (agent, Envoy, operator), the most nodes any agent can't reach, failing controllers and Cilium targets down, where green means zero. Next to them are the Gateway's requests by status class and the datapath's drops by reason.

### Alerts

`kube-system/cilium/app/prometheusrule.yaml`:

| Alert | Fires when | For | Severity |
| --- | --- | --- | --- |
| `CiliumAgentUnhealthy` | a `cilium` or `cilium-envoy` DaemonSet pod isn't ready | 10m | critical |
| `CiliumNodeUnreachable` | an agent's health probes to another node (or its health endpoint) fail | 10m | warning |
| `CiliumControllersFailing` | an agent has failing controllers | 15m | warning |
| `CiliumBPFMapPressureHigh` | a BPF map is over 90% full | 10m | warning |

The `for` durations let a Talos upgrade go by: it reboots one node at a time, and while it's down, its agent is unavailable and the other agents can't reach it. A node that stays down also fires `KubeNodeNotReady`.

What to do:

- **`CiliumAgentUnhealthy`**: `kubectl -n kube-system get pods -l k8s-app=cilium -o wide` (or `k8s-app=cilium-envoy`), then the pod's events and logs. `cilium status` (the CLI from devenv) summarises every component.
- **`CiliumNodeUnreachable`**: `kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --all-health` lists which nodes and endpoints fail, over which IP. Usually the other node is down; otherwise check the VMs' network on the Proxmox side.
- **`CiliumControllersFailing`**: `kubectl -n kube-system exec <agent pod> -c cilium-agent -- cilium-dbg status --all-controllers` names the controller and its last error.
- **`CiliumBPFMapPressureHigh`**: the `map_name` label says which map. For the connection-tracking maps (`ct4_global`, `ct_any4_global`), something opens a lot of connections; the sizes are set by `bpf.mapDynamicSizeRatio` in the chart.

## cert-manager

### What is scraped

The chart's ServiceMonitor `cert-manager` (`prometheus.servicemonitor.enabled`, every 60s) scrapes the controller, cainjector and webhook; their `job`s are `cert-manager`, `cainjector` and `webhook`. Only the controller has the certificate metrics:

- `certmanager_certificate_expiration_timestamp_seconds`, `certmanager_certificate_renewal_timestamp_seconds`: when each Certificate expires, and when cert-manager will (or should have) renewed it.
- `certmanager_certificate_ready_status{condition="True|False|Unknown"}`: one series per value, 1 for the current one. Same for `certmanager_clusterissuer_ready_status`.
- `certmanager_http_acme_client_request_count`, `certmanager_controller_sync_error_count`: requests to Let's Encrypt, and reconcile errors.

`honorLabels: true` keeps each Certificate's own `namespace` label (`kube-system` for the Gateway's wildcard, `cnpg-system` for the barman-cloud plugin's), rather than renaming it `exported_namespace`. That way certificate alerts group with the app's other alerts.

### The dashboard

**cert-manager** (`/d/cert-manager`, folder **Network**), from `cert-manager/app/dashboards/cert-manager.json` (the chart ships none):

- **Overview**: number of certificates, how many aren't ready or are past their renewal time, the soonest expiry, ClusterIssuers not ready, targets down. Below, a table of every Certificate with its issuer, Ready condition, time to expiry and time to renewal, soonest expiry first.
- **Expiry over time**: time left per certificate (a sawtooth: down, then back up at each renewal), and each Certificate's Ready condition over time.
- **ACME and controllers**: Let's Encrypt requests by host and status, reconcile errors and reconciles per controller.

**Cluster Health** has a **Certificates and ExternalDNS** row with the same table, certificates not ready and the soonest expiry.

### Alerts

`cert-manager/app/prometheusrule.yaml`. Let's Encrypt certificates last 90 days and cert-manager renews them 30 days before they expire, so these only fire when renewal has been failing for a while.

| Alert | Fires when | For | Severity |
| --- | --- | --- | --- |
| `CertificateExpiringSoon` | under 14 days left | 1h | warning |
| `CertificateExpiringSoon` | under 3 days left | 1h | critical (mutes the warning) |
| `CertificateRenewalFailed` | more than an hour past the renewal time | 15m | warning |
| `CertificateNotReady` | Ready isn't True | 15m | warning |
| `CertManagerIssuerNotReady` | a ClusterIssuer's Ready isn't True | 15m | warning |
| `CertManagerAbsent` | no `up` cert-manager controller target | 15m | warning |

`CertManagerAbsent` is there because every other rule needs the controller's metrics: if it isn't scraped, the series vanish and the expiry alerts can never fire.

### When a certificate alert fires

The certificate that matters most is `kube-system/wildcard`: the Gateway's `*.<domain>` certificate, from ClusterIssuer `cloudflare-cluster-issuer` (Let's Encrypt, DNS-01 through Cloudflare). If it expires, every app's HTTPS breaks. The current certificate keeps working until its expiry, so there's time.

1. **Find where issuance stops.** A renewal goes Certificate → CertificateRequest → Order → Challenge; the first object that isn't happy has the reason in its status and events:

   ```sh
   kubectl get certificate -A
   kubectl describe certificate wildcard -n kube-system
   kubectl get certificaterequest,order,challenge -n kube-system
   kubectl describe challenge -n kube-system      # DNS-01 problems show up here
   kubectl -n cert-manager logs deploy/cert-manager --tail=100
   ```

2. **Common causes**, for the Cloudflare issuer:
   - **The Cloudflare API token** (Secret `cloudflare-token` in `cert-manager`, key `apiToken`) expired, was revoked or lost its `Zone:DNS:Edit` permission: the Challenge says `Cloudflare API error`. Make a new token, update `cert-manager/cert-manager/app/secret.sops.yaml` ([SOPS](/kubernetes/sops)) and reconcile. `CertManagerIssuerNotReady` fires if the ACME account itself is the problem.
   - **Propagation check failing**: cert-manager checks the TXT record against `1.1.1.1` and `1.0.0.1` (`--dns01-recursive-nameservers`). A Challenge stuck in `pending` with "propagation check failed" means Cloudflare isn't serving the `_acme-challenge` record: check it with `dig TXT _acme-challenge.<domain> @1.1.1.1`.
   - **Let's Encrypt rate limits**: the Order fails with `429` or `rateLimited` (also visible on the dashboard's ACME panel). They reset within a week; don't delete and recreate the Certificate in a loop.
3. **Retry once the cause is fixed.** cert-manager retries on its own with backoff, up to an hour apart. To retry now, trigger a renewal with `cmctl` (not installed; ask before `nix run nixpkgs#cmctl -- renew wildcard -n kube-system`).
4. **The barman-cloud certificates** (`cnpg-system/barman-cloud-client` and `-server`) come from the plugin's self-signed Issuer, so no ACME is involved. If they fail, check the plugin's Issuer: `kubectl -n cnpg-system get issuer,certificate`.

**`CertificateNotReady`** alone, with plenty of time left, is often a Certificate whose spec changed (a new DNS name) and whose new issuance is failing: the steps are the same.

### Testing

To see the alert path without touching the real certificate, apply a throwaway Certificate from the staging issuer for a name Cloudflare doesn't host (say `test.invalid`): its Challenge fails, `CertificateNotReady` fires after 15 minutes. Delete it afterwards.
