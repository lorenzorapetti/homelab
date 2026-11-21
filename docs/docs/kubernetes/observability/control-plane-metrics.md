---
sidebar_position: 3
sidebar_label: Control-plane metrics
---

# Control-plane metrics

Prometheus scrapes kube-controller-manager, kube-scheduler and etcd on all three nodes. This fills the chart's **etcd**, **Kubernetes / Controller Manager** and **Kubernetes / Scheduler** dashboards, and turns on their alerts (`KubeControllerManagerDown`, `KubeSchedulerDown`, `etcdMembersDown`, `etcdInsufficientMembers`, `etcdHighFsyncDurations`…).

It takes two changes: a Talos patch that makes the components listen on the node's LAN address, and the chart values that scrape them. Why the ports can be open on the LAN without a firewall is in [ADR 0004](https://github.com/lorenzorapetti/homelab/blob/main/docs/adr/0004-control-plane-metrics-on-the-lan.md).

## Why a Talos patch is needed

The three components run as Talos static pods with host networking, and by default they listen only on `127.0.0.1`. The controller-manager and scheduler run with `--bind-address=127.0.0.1`, and etcd has no metrics listener at all (its metrics are only on the mTLS client port 2379). Prometheus runs in a pod, so it can't reach any of them.

## The Talos patch

`talos/control-plane/10-metrics.yaml`:

```yaml
apiVersion: v1alpha1
kind: KubeControllerManagerConfig
extraArgs:
  bind-address: 0.0.0.0
---
apiVersion: v1alpha1
kind: KubeSchedulerConfig
extraArgs:
  bind-address: 0.0.0.0
---
cluster:
  etcd:
    extraArgs:
      listen-metrics-urls: http://0.0.0.0:2381
```

- **`KubeControllerManagerConfig` / `KubeSchedulerConfig`** are the Talos 1.14 documents for these static pods ([reference](https://docs.siderolabs.com/talos/v1.14/reference/configuration/kubernetes/kubecontrollermanagerconfig.md)). The patch changes only the bind address. The secure ports stay 10257 and 10259, and `/metrics` still needs an authenticated, authorized client.
- **etcd** has no document of its own in Talos 1.14, so the last part patches the v1alpha1 `cluster.etcd.extraArgs`. `listen-metrics-urls` opens a second, plain-HTTP listener that serves only `/metrics` and `/health`, as in the Talos guide "Expose the Etcd Metrics Endpoint". Client and peer traffic keep their mTLS ports (2379, 2380).

A config rendered with this patch passes `talosctl validate --mode metal --strict`.

### Applying it, one node at a time

Inside `devenv shell`, with the YubiKey plugged in:

```bash
talosctl etcd members -n 10.0.11.1          # three members before starting
just talos::diff --nodes-filter '^talos-1$' # only the three extraArgs should change
just talos::apply --nodes-filter '^talos-1$'
```

`topf apply` asks before applying, applies in `auto` mode, and waits for the node to stay Ready for 30 seconds afterwards. The controller-manager and scheduler static pods restart with the new flag on their own. **etcd does not**: the apply updates the etcd spec (`talosctl get etcdspec`) without rebooting, and the running etcd keeps its old flags until it restarts. `talosctl service etcd restart` is refused ("doesn't support restart operation via API"), so reboot the node you just patched:

```bash
talosctl -n 10.0.11.1 reboot --wait
kubectl wait --for=condition=Ready node/talos-1 --timeout=5m
curl -s http://10.0.11.1:2381/health        # {"health":"true","reason":""}
```

On 2026-11-21 the rollout went this way: apply on all three nodes, then one reboot per node. Each node was back within a few minutes, etcd kept three members throughout, and rebooting the leader (`talos-3`) moved leadership to `talos-1` once.

After each node, before moving on:

```bash
kubectl get nodes                           # all Ready
talosctl -n 10.0.11.1 etcd status           # all three members, one leader, no errors
talosctl -n 10.0.11.1 service etcd          # Running, healthy
```

Then repeat for `talos-2` (`10.0.11.2`) and `talos-3` (`10.0.11.3`). Applying node by node keeps two etcd members up at all times, so quorum holds even if a node restarts etcd or reboots. Finish with `just talos::diff`, which should show no changes.

## The chart values

In `kube-prometheus-stack/app/helmrelease.yaml`:

```yaml
kubeControllerManager:
  endpoints: &controlPlaneNodes [10.0.11.1, 10.0.11.2, 10.0.11.3]
kubeScheduler:
  endpoints: *controlPlaneNodes
kubeEtcd:
  endpoints: *controlPlaneNodes
  serviceMonitor:
    authorization: null
```

With `endpoints` set, the chart creates a headless Service and a hand-written `Endpoints` object per component in `kube-system`, pointing at the node IPs, plus a `ServiceMonitor` for each. **Adding or replacing a node means updating this list.**

| Component | Port | Scheme | Auth |
| --- | --- | --- | --- |
| kube-controller-manager | 10257 | HTTPS, `insecureSkipVerify` | Prometheus's ServiceAccount token |
| kube-scheduler | 10259 | HTTPS, `insecureSkipVerify` | Prometheus's ServiceAccount token |
| etcd | 2381 | HTTP | none |

These are the chart's defaults, apart from etcd's `authorization: null`: by default the chart sends Prometheus's token to etcd too, which over plain HTTP would only put it on the wire in clear text. `insecureSkipVerify` is needed because the controller-manager and scheduler serve self-signed certificates. Prometheus's ClusterRole already allows `get` on the `/metrics` non-resource URL.

Turning the targets on also brings back the dashboards and rules that the chart left out while they were off.

## Checks

Bind addresses, on every node:

```bash
for c in kube-controller-manager kube-scheduler; do
  kubectl -n kube-system get pods -l k8s-app=$c -o json \
    | jq -r '.items[] | "\(.spec.nodeName)  \(.metadata.labels["k8s-app"])  \(.spec.containers[0].command[] | select(startswith("--bind-address")))"'
done
# six lines, each ending in --bind-address=0.0.0.0
```

etcd's metrics listener answers on every node:

```bash
for ip in 10.0.11.1 10.0.11.2 10.0.11.3; do
  curl -s http://$ip:2381/metrics | grep -m1 '^etcd_server_has_leader'
done
# etcd_server_has_leader 1, three times
```

The controller-manager and scheduler still refuse anonymous requests. **This must return 401 or 403**; a 200 means the authentication assumption in [ADR 0004](https://github.com/lorenzorapetti/homelab/blob/main/docs/adr/0004-control-plane-metrics-on-the-lan.md) no longer holds:

```bash
curl -sk -o /dev/null -w '%{http_code}\n' https://10.0.11.1:10257/metrics   # 401 or 403
curl -sk -o /dev/null -w '%{http_code}\n' https://10.0.11.1:10259/metrics   # 401 or 403
curl -sk https://10.0.11.1:10257/healthz                                    # ok (anonymous by design)
```

Prometheus has three targets up for each job:

```bash
kubectl port-forward -n observability svc/kube-prometheus-stack-prometheus 9090 &
curl -s localhost:9090/api/v1/query \
  --data-urlencode 'query=sum by (job) (up{job=~"kube-etcd|kube-scheduler|kube-controller-manager"})' \
  | jq -r '.data.result[] | "\(.metric.job) \(.value[1])"'
# kube-controller-manager 3, kube-etcd 3, kube-scheduler 3
```

In Grafana, the **etcd**, **Kubernetes / Controller Manager** and **Kubernetes / Scheduler** dashboards (folder **Kubernetes**) show data for all three nodes. In Alertmanager, `KubeControllerManagerDown`, `KubeSchedulerDown` and `etcdMembersDown` are not firing.

## Troubleshooting

- **Targets down with `connection refused`**: the Talos patch isn't applied on that node. Check its bind addresses as above, and `just talos::diff`.
- **etcd target refused, but `just talos::diff` shows no changes**: etcd hasn't restarted since the apply. `talosctl -n <ip> get etcdspec -o yaml` shows `listen-metrics-urls`, but the running process doesn't have it (`talosctl -n <ip> read /proc/<etcd pid>/cmdline`). Reboot the node (`talosctl -n <ip> reboot --wait`), one node at a time.
- **Controller-manager or scheduler targets down with 401 or 403**: Prometheus's token isn't accepted. Check that Secret `kube-prometheus-stack-prometheus-token` exists in `observability` and that the Prometheus ClusterRole has the `/metrics` non-resource URL.
- **Alerts firing right after enabling the targets**: `KubeControllerManagerDown` and `KubeSchedulerDown` fire when the job has no targets. If the chart values reached the cluster before the Talos patch did, they fire until all three nodes are patched.
