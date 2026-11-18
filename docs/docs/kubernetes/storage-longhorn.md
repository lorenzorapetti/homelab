---
sidebar_position: 5
sidebar_label: "Storage: Longhorn"
---

# Storage: Longhorn

Persistent volumes come from [Longhorn](https://longhorn.io/) running inside the cluster. It replaces the external Ceph cluster and ceph-csi that the k3s setup used. Jonas made the same choice ([post 1](https://jonashietala.se/blog/2026/05/05/planning_my_kubernetes_homelab)). Current release: **v1.13.0** ([releases](https://github.com/longhorn/longhorn/releases)).

Two sources describe Longhorn on Talos, and they don't fully agree:

- the [Talos Longhorn guide](https://docs.siderolabs.com/kubernetes-guides/csi/longhorn.md), written for Talos 1.14
- [Longhorn's Talos page](https://longhorn.io/docs/latest/advanced-resources/os-distro-specific/talos-linux-support/), in the Longhorn 1.13.0 docs, whose newest Talos references are v1.10/v1.11

The sections below follow the Talos guide and note where the two differ.

## Talos side

### System extensions

Every node needs:

- `siderolabs/iscsi-tools`, which "provides iscsid and iscsiadm for persistent volume operations"
- `siderolabs/util-linux-tools`, which "provides fstrim for filesystem trimming"

([Talos guide](https://docs.siderolabs.com/kubernetes-guides/csi/longhorn.md), [Longhorn page](https://longhorn.io/docs/latest/advanced-resources/os-distro-specific/talos-linux-support/)). They are in `talos/schematic.yaml` next to `qemu-guest-agent` ([Preparing the servers](/kubernetes/getting-started/preparing-the-servers#talos-image-the-schematic)). Adding them later means changing the schematic and running `topf upgrade`.

### Talos machine config

`talos/all/20-longhorn.yaml`:

```yaml
apiVersion: v1alpha1
kind: UserVolumeConfig
name: longhorn
provisioning:
  diskSelector:
    match: "!system_disk"     # the separate scsi1 data disk; check with talosctl get disks
  grow: false
```

- **A user volume, not `/var/lib/longhorn`.** A `UserVolumeConfig` allocates a partition on the matching disk and mounts it at `/var/mnt/<name>`, here `/var/mnt/longhorn`. The default filesystem is `xfs` ([UserVolumeConfig reference](https://docs.siderolabs.com/talos/v1.14/reference/configuration/block/uservolumeconfig.md)).
- **The selector.** The Talos guide matches `disk.transport == 'nvme' && !system_disk`. The VMs present a SCSI disk, so I keep only `!system_disk`. **Unverified:** that `!system_disk` alone matches only the data disk on these VMs and not, say, the cloud-init drive. Check `talosctl get disks` before applying.

#### About kubelet `extraMounts`

Older guides bind-mount `/var/lib/longhorn` into the kubelet with `machine.kubelet.extraMounts` (`bind`, `rshared`, `rw`). Longhorn's page labels that approach **Talos v1.9.x and earlier**. For Talos v1.10+, it uses a `UserVolumeConfig` at `/var/mnt/longhorn` and *also* lists a kubelet extra mount for `/var/mnt/longhorn` ([Longhorn page](https://longhorn.io/docs/latest/advanced-resources/os-distro-specific/talos-linux-support/)). The Talos 1.14 guide uses only the `UserVolumeConfig` and mentions no extra mount ([Talos guide](https://docs.siderolabs.com/kubernetes-guides/csi/longhorn.md)). Talos 1.14's new `KubeletConfig` document has no `extraMounts` field ([reference](https://docs.siderolabs.com/talos/v1.14/reference/configuration/kubernetes/kubeletconfig.md)), so an extra mount would have to use the legacy `machine.kubelet.extraMounts` field.

**Unverified:** whether the extra mount is still needed on 1.14. Start with the Talos guide's config. If Longhorn volumes fail to attach, add this, following Longhorn's v1.10+ instructions:

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

Each VM has a separate Longhorn virtual disk (`scsi1`) next to the Talos system disk (`scsi0`); see [sizing](/kubernetes/getting-started/preparing-the-servers#sizing).

- The Talos guide recommends "at least one dedicated disk per storage node" ([guide](https://docs.siderolabs.com/kubernetes-guides/csi/longhorn.md)).
- Longhorn recommends an optional `VolumeConfig` to size Talos's own system volumes, so you don't need `storageReservedPercentageForDefaultDisk` ([Longhorn page](https://longhorn.io/docs/latest/advanced-resources/os-distro-specific/talos-linux-support/)). With a dedicated data disk, this doesn't apply.
- While all three VMs live on one Proxmox host, Longhorn's three replicas sit on the same physical SSD. That protects against a VM failing, not against the disk failing. Backups matter more than replicas until hosts `.2` and `.3` exist.

## Kubernetes side (an app in the migration)

Longhorn is added through Flux like any other app ([Migrating from k3s](/kubernetes/migration)). The pieces:

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

The chart is served from `https://charts.longhorn.io` ([Talos guide](https://docs.siderolabs.com/kubernetes-guides/csi/longhorn.md)). I haven't verified whether an OCI copy exists, so use a `HelmRepository` with `chart.spec` (see [charts without an OCI registry](/kubernetes/flux/repository-architecture#charts-without-an-oci-registry)). The one value both sources require:

```yaml
values:
  defaultSettings:
    defaultDataPath: /var/mnt/longhorn
```

This is the Talos guide's `--set defaultSettings.defaultDataPath=/var/mnt/longhorn` for the V1 data engine. The V2 engine needs a raw block device, huge pages and extra kernel modules ([Talos guide](https://docs.siderolabs.com/kubernetes-guides/csi/longhorn.md)), so I'm not using it.

The `ks.yaml` should health-check the `HelmRelease`, and every app with a PVC should `dependsOn` `longhorn`.

## Data from the old cluster

The k3s apps kept their data on the external Ceph cluster (`ceph-rbd` / `cephfs` storage classes). **Nothing moves automatically.** For each PVC-backed app (actual, pgadmin, netbox, portainer, rabbitmq, and gitea's PVC), choose one of:

- **Copy.** While the Ceph cluster is still reachable, mount the old RBD image or CephFS path outside Kubernetes (for example on a Proxmox host). Then copy the files into the new Longhorn PVC through a temporary pod.
- **Restore.** Use the app's own export/backup feature, if it has one, and import it into the fresh install. Check each app's docs; I haven't verified which ones offer this.
- **Start fresh** when the data isn't worth keeping.

Write the plan down per app at its migration step, and do it **before** the Ceph cluster is torn down.
