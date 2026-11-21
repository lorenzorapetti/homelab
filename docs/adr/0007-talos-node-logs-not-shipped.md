# Talos node logs are not shipped to Loki (yet)

Loki has the logs of every pod, including the control-plane static pods (kube-apiserver, kube-controller-manager, kube-scheduler), which Talos runs as ordinary containers. It does not have the logs of Talos's own services (machined, apid, trustd, containerd, the kubelet, etcd) or the kernel ring buffer. These stay where Talos keeps them, in memory on each node, read with `talosctl logs <service>` and `talosctl dmesg`.

Talos can send them over the network (`machine.logging.destinations`, and `KmsgLogConfig` for the kernel), but only as JSON lines over TCP or UDP. Alloy has no generally-available component that reads that format. The one that could, `loki.source.syslog` with `syslog_format = "raw"`, is experimental, and enabling it means running every Alloy pod with `--stability.level=experimental`, which turns on every experimental feature, not just this one.

This is the right trade-off for now because:

- **It keeps the log pipeline on stable components only.** Alloy is what makes logs reliable. Running it on experimental features to collect logs that are rarely needed makes the common case less reliable for the rare one.
- **The logs that matter most are already in Loki.** Control-plane pods, Cilium, CoreDNS, Longhorn and Flux are all pods. What's left is mostly Talos's own bookkeeping, which matters when a node is in trouble, often when it can't ship logs anyway.
- **It needs no Talos change.** Shipping means a machine-config patch on every node and a listener Talos can reach before the CNI is up.

## Considered options

- **A second Alloy, or a second process in each Alloy pod, with `stability.level=experimental`.** It keeps the experimental flag away from pod-log shipping, but adds pods on nodes that are already short of memory, and a hostPort or host-network listener per node.
- **Vector as the receiver.** Vector reads Talos's JSON lines natively (its `socket` source) and is what Talos's own docs show. It's a second log agent to configure and monitor, next to Alloy.
- **Talos → syslog → Alloy.** Talos doesn't send syslog, so this needs a converter in the middle: the same extra component as above.

## Consequences

- Talos service logs and `dmesg` are lost when a node reboots, and can only be read with `talosctl` while the node is up. To debug a node that crashed, use what's still on the node, or the Proxmox console.
- Revisit when `raw` reaches public preview or general availability in Alloy. Then: a `loki.source.syslog` listener (UDP, `syslog_format = "raw"`) in the existing DaemonSet on a hostPort, a `loki.process` stage that parses the JSON (`talos-service`, `talos-level`, `msg`), and a Talos patch sending `machine.logging` and `KmsgLogConfig` to `udp://127.0.0.1:<port>`.
