# Control-plane metrics are exposed on the LAN without a firewall

Prometheus scrapes kube-controller-manager, kube-scheduler and etcd on each control-plane node's LAN address. Talos binds all three to `127.0.0.1` by default, so a control-plane patch (`talos/control-plane/10-metrics.yaml`) binds the controller-manager and scheduler to `0.0.0.0`, and turns on etcd's separate metrics listener at `http://0.0.0.0:2381`. No ingress firewall restricts who can reach these ports.

This is acceptable because:

- **The controller-manager (10257) and scheduler (10259) still authenticate and authorize.** Both run with authentication and authorization kubeconfigs, so `/metrics` needs a token that the API server accepts and RBAC allows. Only `/healthz`, `/readyz` and `/livez` are anonymous. Changing the bind address changes who can connect, not who is let in.
- **etcd's 2381 listener serves only `/metrics` and `/health`.** It has no authentication, but it is a separate listener from the client port. Reads and writes to the keyspace stay on 2379, behind mutual TLS. What leaks is operational data: database size, request rates, leader changes.
- **The nodes are only on the LAN.** Nothing forwards these ports from the internet. The LAN and the tailnet are trusted to the same degree as for every other cluster service.

## Considered options

- **Leave them off.** The chart's etcd, scheduler and controller-manager dashboards and alerts stay empty. Etcd problems (slow disks, leader churn) are the ones most likely to take the cluster down, so they are worth watching.
- **Talos ingress firewall (`NetworkRuleConfig`) allowing only the node and pod CIDRs.** This would close the ports to the rest of the LAN. It was left out for now: a default-deny ingress policy on the nodes has to list every port Talos, Kubernetes, Cilium and Longhorn need, and a mistake there can cut off the API or etcd peers. It is worth doing as its own change.
- **Scrape through a proxy on each node** (a DaemonSet with `hostNetwork` that forwards `127.0.0.1` to a pod port, or kube-rbac-proxy). It keeps the components on localhost, but adds a component per node and still exposes a port, only a different one.
- **Scrape etcd over its client port with a client certificate.** It keeps etcd metrics behind mTLS, but needs an etcd client certificate in the cluster as a Secret. That certificate could read and write the whole keyspace, which is far worse to leak than metrics.

## Consequences

- Anyone on the LAN can read etcd's metrics from `http://<node-ip>:2381/metrics`. Prometheus does not send its token there (`kubeEtcd.serviceMonitor.authorization: null`), since plain HTTP would put it on the wire in clear text.
- An anonymous request to 10257 or 10259 `/metrics` must be refused with 401 or 403. The control-plane metrics docs include this check; if it ever succeeds, the authentication assumption no longer holds and this decision must be revisited.
- Revisit this if any of these change: a node gets a public or less trusted interface, the LAN is shared with untrusted devices, a Talos or Kubernetes release changes the controller-manager's or scheduler's default authentication, or etcd's metrics listener starts serving more than `/metrics` and `/health`. The ingress firewall above is the next step in each case.
