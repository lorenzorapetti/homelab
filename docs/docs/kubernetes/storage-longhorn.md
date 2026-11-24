---
sidebar_position: 5
sidebar_label: "Storage: Longhorn"
---

# Storage: Longhorn

Persistent volumes come from [Longhorn](https://longhorn.io/) running inside the cluster. Jonas made the same choice ([post 1](https://jonashietala.se/blog/2026/05/05/planning_my_kubernetes_homelab)). Current release: **v1.13.0** ([releases](https://github.com/longhorn/longhorn/releases)).

Two sources describe Longhorn on Talos, and they don't fully agree:

- the [Talos Longhorn guide](https://docs.siderolabs.com/kubernetes-guides/csi/longhorn.md), written for Talos 1.14
- [Longhorn's Talos page](https://longhorn.io/docs/latest/advanced-resources/os-distro-specific/talos-linux-support/), in the Longhorn 1.13.0 docs, whose newest Talos references are v1.10/v1.11

The sections below follow the Talos guide and note where the two differ.

## Talos side

### System extensions

Every node needs:

- `siderolabs/iscsi-tools`, which "provides iscsid and iscsiadm for persistent volume operations"
- `siderolabs/util-linux-tools`, which "provides fstrim for filesystem trimming"

([Talos guide](https://docs.siderolabs.com/kubernetes-guides/csi/longhorn.md), [Longhorn page](https://longhorn.io/docs/latest/advanced-resources/os-distro-specific/talos-linux-support/)). They are in `talos/schematic.yaml` next to `qemu-guest-agent` ([Deploying the infrastructure](/kubernetes/getting-started/deploying-the-infrastructure#talos-image-the-schematic)). Adding them later means changing the schematic and running `topf upgrade`.

### Talos machine config

`talos/all/20-longhorn.yaml`:

```yaml
apiVersion: v1alpha1
kind: UserVolumeConfig
name: longhorn
provisioning:
  diskSelector:
    match: "!system_disk && !disk.cdrom && !disk.readonly"
  minSize: 150GB
  grow: true
```

- **A user volume, not `/var/lib/longhorn`.** A `UserVolumeConfig` allocates a partition on the matching disk and mounts it at `/var/mnt/<name>`, here `/var/mnt/longhorn`. The default filesystem is `xfs` ([UserVolumeConfig reference](https://docs.siderolabs.com/talos/v1.14/reference/configuration/block/uservolumeconfig.md)).
- **The selector.** The Talos guide matches `disk.transport == 'nvme' && !system_disk`. These VMs have no NVMe disk. `talosctl get disks --insecure` shows `sda` (system), `sdb` (the 215 GB `scsi1` data disk) and `sr0`, the 4.2 MB cloud-init drive with `cdrom: true` and `readonly: true`. `!system_disk` alone would also match `sr0`, so the selector excludes CD-ROMs and read-only disks too.
- **The size.** Talos 1.14 requires `minSize` or `maxSize`: without one, `talosctl validate` fails with "min size or max size is required". `minSize: 150GB` also keeps the volume off any small disk, and `grow: true` lets the partition fill the rest of the 200 GB disk (and follow it if the disk is resized in Proxmox).

#### About kubelet `extraMounts`

Older guides bind-mount `/var/lib/longhorn` into the kubelet with `machine.kubelet.extraMounts` (`bind`, `rshared`, `rw`). Longhorn's page labels that approach **Talos v1.9.x and earlier**. For Talos v1.10+, it uses a `UserVolumeConfig` at `/var/mnt/longhorn` and *also* lists a kubelet extra mount for `/var/mnt/longhorn` ([Longhorn page](https://longhorn.io/docs/latest/advanced-resources/os-distro-specific/talos-linux-support/)). The Talos 1.14 guide uses only the `UserVolumeConfig` and mentions no extra mount ([Talos guide](https://docs.siderolabs.com/kubernetes-guides/csi/longhorn.md)). Talos 1.14's new `KubeletConfig` document has no `extraMounts` field ([reference](https://docs.siderolabs.com/talos/v1.14/reference/configuration/kubernetes/kubeletconfig.md)), so an extra mount would have to use the legacy `machine.kubelet.extraMounts` field.

**Not needed on Talos 1.14 (verified 2026-11-19).** With only the `UserVolumeConfig`, Longhorn found the disk on every node, and a test volume attached, mounted and was read on a node that held none of its replicas ([as built](#as-built-2026-11-19)). For reference, Longhorn's v1.10+ instructions add this, in case a future version needs it:

```yaml
machine:
  kubelet:
    extraMounts:
      - destination: /var/mnt/longhorn
        type: bind
        source: /var/mnt/longhorn
        options: [bind, rshared, rw]
```

#### Talos upgrades

Talos v1.8+ sets `--preserve` automatically on upgrade. Before that, an upgrade without it wiped `/var/lib/longhorn` ([Longhorn page](https://longhorn.io/docs/latest/advanced-resources/os-distro-specific/talos-linux-support/)). A user volume on its own disk isn't touched by the system install in any case.

### VM disks

Each VM has a separate Longhorn virtual disk (`scsi1`) next to the Talos system disk (`scsi0`); see [sizing](/kubernetes/getting-started/deploying-the-infrastructure#sizing).

- The Talos guide recommends "at least one dedicated disk per storage node" ([guide](https://docs.siderolabs.com/kubernetes-guides/csi/longhorn.md)).
- Longhorn recommends an optional `VolumeConfig` to size Talos's own system volumes, so you don't need `storageReservedPercentageForDefaultDisk` ([Longhorn page](https://longhorn.io/docs/latest/advanced-resources/os-distro-specific/talos-linux-support/)). With a dedicated data disk, this doesn't apply.
- talos-1 and talos-2 share hecate's SSD, and talos-3 has persephone's. Without help, Longhorn doesn't know which VM is on which host, so a volume's two replicas could both land on hecate, and a failed hecate SSD would lose the volume. So each node carries its Proxmox host as `topology.kubernetes.io/zone` (`hecate` or `persephone`), set by `talos/all/30-zone.yaml.tpl` from `data.proxmoxHost` in `topf.yaml`. Longhorn "relies on label `topology.kubernetes.io/zone`" to identify zones, and `replica-zone-soft-anti-affinity` (default `true`) makes it prefer a different zone for a volume's next replica ([settings](https://longhorn.io/docs/1.13.0/references/settings/)). `replicaAutoBalance: best-effort` moves replicas that were already placed in the same zone ([auto balance](https://longhorn.io/docs/1.13.0/high-availability/auto-balance-replicas/)). As a result, persephone's 200GB disk holds a copy of every volume, so usable space is about 200GB, not 300GB. Backups still matter more than replicas. When a VM moves to another host, change `proxmoxHost` along with `proxmox_node` in the tfvars.
- The VM disks are thin LVM volumes, and nothing in Talos trims them. The `fstrim` DaemonSet (`kubernetes/apps/kube-system/fstrim`) trims `/var` and `/var/mnt/longhorn` on every node at start and then weekly, so freed blocks go back to the Proxmox thin pool.

## Kubernetes side

Longhorn is added through Flux like any other app ([Adding apps](/kubernetes/adding-apps)). The pieces:

`kubernetes/apps/longhorn-system/namespace.yaml`:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: longhorn-system
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
```

Talos enables Pod Security Admission and applies `baseline` to every namespace except `kube-system`, while Longhorn "requires pod security `enforce: "privileged"`" ([Longhorn page](https://longhorn.io/docs/latest/advanced-resources/os-distro-specific/talos-linux-support/)). The Talos guide sets the same label with `kubectl label namespace longhorn-system pod-security.kubernetes.io/enforce=privileged` ([guide](https://docs.siderolabs.com/kubernetes-guides/csi/longhorn.md)). `audit`/`warn` are my additions to keep the logs quiet.

The chart is served from `https://charts.longhorn.io` ([Talos guide](https://docs.siderolabs.com/kubernetes-guides/csi/longhorn.md)). There is no OCI copy: the [longhorn/charts README](https://github.com/longhorn/charts) only documents `helm repo add`, and neither `ghcr.io/longhorn/charts` nor Docker Hub serves one (checked 2026-11-19). So the app uses a `HelmRepository` with `chart.spec` (see [charts without an OCI registry](/kubernetes/flux/repository-architecture#charts-without-an-oci-registry)). The one value both sources require:

```yaml
values:
  defaultSettings:
    defaultDataPath: /var/mnt/longhorn
```

This is the Talos guide's `--set defaultSettings.defaultDataPath=/var/mnt/longhorn` for the V1 data engine. The V2 engine needs a raw block device, huge pages and extra kernel modules ([Talos guide](https://docs.siderolabs.com/kubernetes-guides/csi/longhorn.md)), so I'm not using it.

The `ks.yaml` should health-check the `HelmRelease`, and every app with a PVC should `dependsOn` `longhorn`.

### As built (2026-11-19)

The files are in `kubernetes/apps/longhorn-system/`: the namespace above, `longhorn/ks.yaml` (health check on the `HelmRelease`, `timeout: 10m`), and `longhorn/app/` with `helmrepository.yaml` and `helmrelease.yaml`. The chart is pinned to `1.13.0`. Its `kubeVersion` is `>=1.34.0-0`, so the cluster's 1.37.2 qualifies (the 1.34 minimum comes from the CSI external-provisioner v6.3.0, per the [v1.13.0 release notes](https://github.com/longhorn/longhorn/releases/tag/v1.13.0)). The values beyond `defaultDataPath`:

```yaml
values:
  defaultSettings:
    defaultDataPath: /var/mnt/longhorn
    defaultReplicaCount: 2          # volumes created outside a StorageClass
    replicaAutoBalance: best-effort # added 2026-11-21: one replica per Proxmox host (VM disks)
  persistence:
    defaultClass: true
    defaultClassReplicaCount: 2
    reclaimPolicy: Delete
  longhornUI:
    replicas: 1
```

- **Default StorageClass: `longhorn`.** It's the only storage in the cluster, so a PVC without `storageClassName` lands there. The chart also creates `longhorn-static` for pre-existing volumes.
- **Two replicas, set in the chart values.** The chart writes `numberOfReplicas` into the `longhorn` StorageClass from `persistence.defaultClassReplicaCount`, and `defaultSettings.defaultReplicaCount` covers volumes made in the UI. Two replicas keep a volume available with one node down (a Talos upgrade, a VM failure). With one replica per Proxmox host (see [VM disks](#vm-disks)), two replicas also survive one host or SSD failing. A third would land on hecate again, so it would only cost another copy of every write. Go to 3 when there is a third host.
- **The UI** was a `ClusterIP` service only at first. It's now at `https://longhorn.<domain>`, behind authentik ([The UI](#the-ui)).
- **The disk.** `talosctl get volumestatus u-longhorn` shows a 215 GB `/dev/sdb1` on each node, and `talosctl get mountstatus u-longhorn` shows it as `xfs` at `/var/mnt/longhorn`. Longhorn reports one schedulable disk of 214.6 GB per node.
- **First install.** Flux reported the `HelmRelease` Ready after about 4 minutes. The CSI sidecars and instance managers needed another ~10 minutes, almost all of it Docker Hub image pulls.
- **Test.** A 1 Gi PVC was written from a pod on `talos-1` (replicas on `talos-1` and `talos-3`), then read back from a pod on `talos-2`. Deleting the PVC removed the PV, the Longhorn volume and both replicas.

**Resource use, idle, no volumes** (open question 3): about 170–190 MB of container memory and ~30 millicores of CPU per node. Node "used" memory went from ~1.5 GB to ~1.95 GB of 4.3 GB (measured with `talosctl memory` and `talosctl stats --namespace cri`; there's no metrics-server yet). Each attached volume adds an engine and replica process on top of that.

**Not done yet: backups.** Neither a Longhorn backup target nor VolSync/Restic is set up ([Data](/kubernetes/adding-apps#data)).

## The UI

The Longhorn UI is at `https://longhorn.<domain>`. It has no login of its own, and anyone who reaches it can delete volumes, so it sits behind authentik forward auth for `authentik Admins` only, just like Prometheus and Alertmanager ([Authentik forward auth](/kubernetes/observability/intro#authentik-forward-auth)):

- **The route** is `longhorn/ui/httproute.yaml`, HTTPRoute `longhorn` in `longhorn-system`. It sends `/` to Service `longhorn-frontend` through the `ExternalAuth` filter, and `/outpost.goauthentik.io` to `authentik-server`. The chart has an `httproute` value, but it can't add that second rule, so I don't use it.
- **Its own Kustomization, `longhorn-ui`** (second document in `longhorn/ks.yaml`). It `dependsOn` `longhorn`, `gateway` and `authentik`. It can't go in `longhorn`, because `authentik-db` needs Longhorn, so `longhorn` depending on `authentik` would be a cycle.
- **On the authentik side:** a `Longhorn` provider, application and policy binding in `forward-auth.yaml`, plus `longhorn-system` in ReferenceGrant `authentik-forward-auth`.

If authentik is down, the UI fails closed. Port-forward to reach it anyway:

```sh
kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80
# http://localhost:8080
```

## Monitoring

Prometheus scrapes every `longhorn-manager` pod on port `manager` (9500) every 30s, through the chart's ServiceMonitor `longhorn-prometheus-servicemonitor` (`metrics.serviceMonitor.enabled`).

**The NetworkPolicy.** The chart's `networkPolicies.restrictInternalTraffic` is on by default. It creates NetworkPolicy `longhorn-manager`, which lets only Longhorn's own pods reach 9500. That port also serves the manager's REST API, so `networkPolicies.metricsScrapeSources` lets in Prometheus's pods only: pods labelled `app.kubernetes.io/name: prometheus` and `operator.prometheus.io/name: kube-prometheus-stack`, in namespace `observability`. Without it the target shows as down with a timeout.

**The metrics** ([Longhorn metrics](https://longhorn.io/docs/1.13.0/monitoring/metrics/)):

- **Per volume**: `longhorn_volume_robustness`, `longhorn_volume_state`, `longhorn_volume_capacity_bytes`, `longhorn_volume_actual_size_bytes`, read and write throughput, IOPS and latency. Only the manager on the volume's node reports a volume. The labels are `volume`, `pvc`, `pvc_namespace` and `node`.
- **Per node and disk**: `longhorn_node_status{condition}` and `longhorn_disk_status{condition}` (`ready`, `schedulable`…, value 1 or 0, with `condition_reason`), plus capacity, usage, reservation and scheduled bytes.
- **Robustness and state are labels.** In 1.13 each volume has one series per possible value (`state="healthy|degraded|faulted|unknown"`), with value 1 for the current one. Older dashboards use a numeric value instead (Grafana 13032 and its copies), so their queries don't work here.

### The dashboard

**Longhorn** (`/d/longhorn`, folder **Kubernetes**), filterable by PVC namespace. It's `longhorn/app/dashboards/longhorn.json`, loaded through a `configMapGenerator`.

- **Overview**: number of volumes, degraded and faulted counts, nodes and disks that aren't ready or schedulable, and the fullest disk.
- **Volumes**: a table of every volume with its PVC, robustness, state, size, actual size and node, with unhealthy volumes sorted first. Below it: unhealthy volumes over time, how full each volume is, write throughput, IOPS and write latency.
- **Nodes and disks**: every node and disk condition with its reason, disk usage against the 80% alert line, and scheduled storage per node.
- **Longhorn pods**: CPU and memory of everything in `longhorn-system`, per node.

**Cluster Health** has a **Longhorn** row too. It shows four counters, where green means zero: degraded volumes, faulted volumes, nodes and disks that aren't ready or schedulable, and Longhorn targets down. Next to them are a table listing only the degraded and faulted volumes, and disk usage per node with the 80% alert line.

**Space.** "Usage" is measured against what Longhorn may use: capacity minus the reservation. `storageReservedPercentageForDefaultDisk` is 30% by default, so that's about 150 GB of each 215 GB disk. "Scheduled" is the total size of the replicas placed on a node. With over-provisioning at 100%, Longhorn stops placing new replicas on a node once scheduled storage reaches that 150 GB, even if the replicas aren't full.

### Alerts

`longhorn/app/prometheusrule.yaml`:

| Alert | Fires when | For | Severity |
| --- | --- | --- | --- |
| `LonghornVolumeFaulted` | a volume has no healthy replica | 2m | critical |
| `LonghornVolumeDegraded` | a volume has fewer healthy replicas than configured | 30m | warning |
| `LonghornDiskSpaceLow` | a disk uses more than 80% of capacity minus reservation | 15m | warning |
| `LonghornNodeNotReady` | a node's `ready` condition is False | 10m | warning |
| `LonghornNodeUnschedulable` | a node's `schedulable` condition is False | 30m | warning |
| `LonghornDiskUnschedulable` | a disk's `ready` or `schedulable` condition is False | 15m | warning |

- **Volume alerts carry the PVC's namespace** as `namespace`, so Alertmanager groups them with that app's other alerts. Node and disk alerts carry `longhorn-system`.
- **The `for` durations allow for Talos upgrades.** An upgrade cordons and reboots one node at a time. Its node goes unschedulable while it's cordoned, then not ready while it reboots. Afterwards every volume with a replica on it is degraded until that replica rebuilds, which takes a while for the 20Gi Prometheus volume.
- **If the managers stop being scraped**, the series disappear and these alerts resolve. The chart's `TargetDown` covers that case.

#### When an alert fires

1. Open the Longhorn dashboard, or the UI: **Volume** lists each volume's replicas and where they are, and **Node** lists the disks with their conditions.
2. Depending on the alert:
   - **Degraded**: a replica is missing or rebuilding. Check that every node is ready and schedulable. The UI shows the rebuild's progress under the volume. If no rebuild starts, there's usually no node left with room for the replica: see **Space** above.
   - **Faulted**: every replica failed. Check the volume's events and the instance manager logs on the replicas' nodes (`kubectl -n longhorn-system logs -l longhorn.io/component=instance-manager --tail=100`). Longhorn's [volume recovery](https://longhorn.io/docs/1.13.0/high-availability/recover-volume/) page describes salvaging a replica. For a Postgres volume, restoring from R2 may be quicker ([Backups: Postgres](/kubernetes/backups-postgres)).
   - **Node not ready**: the node or its `longhorn-manager` pod is down. Check `kubectl get nodes` and `kubectl -n longhorn-system get pods -o wide`.
   - **Node or disk unschedulable**: the `condition_reason` label in the notification says why. Common reasons: the node is cordoned, the disk is full, or the disk is missing or not mounted. For a missing disk, check `talosctl get mountstatus u-longhorn` on the node.
   - **Disk space low**: find the volumes that grew on the dashboard. Space freed inside a volume comes back only after it's trimmed (the weekly `fstrim` DaemonSet, see [VM disks](#vm-disks)). If the data really grew, add disk space: [Resizing a VM disk](/kubernetes/getting-started/deploying-the-infrastructure#sizing).

### Testing the alerts

Cordon a node for longer than 30 minutes, for example `kubectl cordon talos-1`. Longhorn marks the node unschedulable within a minute, then `LonghornNodeUnschedulable` fires. Run `kubectl uncordon talos-1` to resolve it.