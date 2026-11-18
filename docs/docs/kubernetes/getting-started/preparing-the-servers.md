---
sidebar_position: 1
---

# Preparing the servers

Talos is an immutable, API-managed OS: no SSH, no shell, no package manager. Preparing the servers comes down to:

1. Choosing a Talos image (an Image Factory **schematic**) with the right system extensions.
2. Creating one Proxmox VM per node with **Terraform**, as Jonas does ([post 2](https://jonashietala.se/blog/2026/05/22/talos_linux_on_proxmox_with_terraform)).

The VMs boot into Talos **maintenance mode** with their final static IPs. [Install Talos](/kubernetes/getting-started/install-talos) then applies the machine config with topf.

## Nodes

| Node | IP | Role |
| --- | --- | --- |
| `talos-1` | `10.0.11.1` | control plane + workloads |
| `talos-2` | `10.0.11.2` | control plane + workloads |
| `talos-3` | `10.0.11.3` | control plane + workloads |

The network map lists only **one Proxmox host for now** (`10.0.10.1`), with `.2` and `.3` to follow. Until the other hosts exist, all three VMs run on that single host. This is the same shape Jonas started with: three control-plane VMs on one Proxmox host ([post 2](https://jonashietala.se/blog/2026/05/22/talos_linux_on_proxmox_with_terraform)). That gives etcd quorum and lets you practise rolling upgrades, but **no hardware redundancy**: if the host dies, the whole cluster goes down with it. Once the other hosts are added, move one VM to each (`node_name` in Terraform). The Kubernetes API VIP is `10.0.11.10`, the gateway is `10.0.0.1`, and the netmask is `/16`. The full address plan is in the [network map](/kubernetes/intro#network-map).

## Talos image: the schematic

Talos images come from the [Image Factory](https://factory.talos.dev/). A schematic lists the system extensions, and the factory derives an ID from it ([Image Factory UI docs](https://docs.siderolabs.com/talos/v1.14/platform-specific-installations/use-the-image-factory-ui.md)). The same ID gives you the disk image Terraform boots and the installer image Talos installs and upgrades from.

`talos/schematic.yaml`:

```yaml
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/qemu-guest-agent     # Proxmox guest agent
      - siderolabs/iscsi-tools          # Longhorn: iscsid + iscsiadm
      - siderolabs/util-linux-tools     # Longhorn: fstrim
```

- **`qemu-guest-agent`** lets Proxmox shut the VM down cleanly. Only enable the Proxmox guest agent option if the image includes it ([Talos Proxmox guide](https://docs.siderolabs.com/talos/v1.14/platform-specific-installations/virtualized-platforms/proxmox.md)).
- **`iscsi-tools` and `util-linux-tools`** are required by Longhorn on every node ([Talos Longhorn guide](https://docs.siderolabs.com/kubernetes-guides/csi/longhorn.md), [Longhorn Talos page](https://longhorn.io/docs/latest/advanced-resources/os-distro-specific/talos-linux-support/)). Jonas notes the same in post 2. See [Storage: Longhorn](/kubernetes/storage-longhorn).

topf reads this file directly with `schematicId: "@schematic.yaml"` and computes the ID locally. A schematic the factory has never seen must be submitted once with `--submit-to-factory` ([topf configuration](https://github.com/postfinance/topf/blob/main/docs/configuration.md#schematic-reference-resolution)). `topf schematic-ids` prints the resolved ID ([docs](https://github.com/postfinance/topf/blob/main/docs/commands/schematic-ids.md)), and Terraform needs that ID to download the image:

```bash
cd talos && topf --submit-to-factory schematic-ids
```

## VMs with Terraform

### Provider

Jonas uses [`bpg/proxmox`](https://registry.terraform.io/providers/bpg/proxmox/latest) 0.95.0 (with `siderolabs/talos` for config). I use only `bpg/proxmox`, because topf handles everything Talos. The latest release is **v0.123.1** (2026-11-18) ([releases](https://github.com/bpg/terraform-provider-proxmox/releases)).

```hcl
# terraform/providers.tf
terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.123.1"
    }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint      # https://10.0.10.1:8006/
  api_token = var.proxmox_api_token     # "terraform@pve!provider=..."
  ssh {
    agent    = true
    username = "root"                   # required with api_token
  }
}
```

These are the provider arguments documented in the [provider docs](https://github.com/bpg/terraform-provider-proxmox/blob/main/docs/index.md). Jonas used username/password and says an API token would be better ([post 2](https://jonashietala.se/blog/2026/05/22/talos_linux_on_proxmox_with_terraform)). SSH is "only required" for a few operations, including disk imports from a local file. Importing with `import_from` goes through the API instead ([When is SSH required?](https://github.com/bpg/terraform-provider-proxmox/blob/main/docs/index.md)). Jonas's disk import broke when his Proxmox login shell was fish, so the SSH user on the Proxmox hosts must use a POSIX shell.

### Image

```hcl
# terraform/image.tf
resource "proxmox_virtual_environment_download_file" "talos" {
  for_each                = toset(var.proxmox_nodes)
  node_name               = each.key
  datastore_id            = "local"
  content_type            = "iso"
  url                     = "https://factory.talos.dev/image/${var.talos_schematic_id}/v${var.talos_version}/nocloud-amd64.raw.xz"
  decompression_algorithm = "zst"
  file_name               = "talos-v${var.talos_version}-nocloud-amd64.img"
}
```

This is Jonas's resource ([post 2](https://jonashietala.se/blog/2026/05/22/talos_linux_on_proxmox_with_terraform)), downloaded once per Proxmox host. It uses the **`nocloud`** image, so the static IP comes from Proxmox cloud-init ([Talos nocloud docs](https://docs.siderolabs.com/talos/v1.14/platform-specific-installations/cloud-platforms/nocloud.md)).

**Unverified:** Jonas's URL ends in `.raw.xz` while `decompression_algorithm` is `zst`. Before the first `apply`, check the real file name and compression in the Image Factory UI. The provider accepts `gz`, `lzo`, `zst` or `bz2`, and compressed images must be attached with `file_id`, not `import_from` ([download_file docs](https://github.com/bpg/terraform-provider-proxmox/blob/main/docs/resources/virtual_environment_download_file.md), [vm docs](https://github.com/bpg/terraform-provider-proxmox/blob/main/docs/resources/virtual_environment_vm.md)).

### VMs

```hcl
# terraform/vms.tf
variable "nodes" {
  default = {
    # All on the first Proxmox host (10.0.10.1) for now; move to .2/.3 later
    "talos-1" = { pve = "<pve-node-name>", ip = "10.0.11.1" }
    "talos-2" = { pve = "<pve-node-name>", ip = "10.0.11.2" }
    "talos-3" = { pve = "<pve-node-name>", ip = "10.0.11.3" }
  }
}

resource "proxmox_virtual_environment_vm" "talos" {
  for_each        = var.nodes
  name            = each.key
  node_name       = each.value.pve
  stop_on_destroy = true

  bios    = "ovmf"
  machine = "q35"
  efi_disk {
    datastore_id = "local-lvm"
    type         = "4m"
  }

  agent { enabled = true }                     # needs the qemu-guest-agent extension
  cpu {
    cores = 2
    type  = "host"
  }
  memory { dedicated = 4608 }                  # no ballooning (floating unset)

  scsi_hardware = "virtio-scsi-pci"            # NOT virtio-scsi-single

  # System disk: Talos (EPHEMERAL holds container images, logs, etcd)
  disk {
    datastore_id = "local-lvm"
    file_id      = proxmox_virtual_environment_download_file.talos[each.value.pve].id
    interface    = "scsi0"
    size         = 50
    discard      = "on"
  }

  # Data disk: Longhorn (UserVolumeConfig "longhorn")
  disk {
    datastore_id = "local-lvm"
    interface    = "scsi1"
    size         = 200
    discard      = "on"
  }

  initialization {
    datastore_id = "local-lvm"
    ip_config {
      ipv4 {
        address = "${each.value.ip}/16"        # flat 10.0.0.0/16 LAN
        gateway = "10.0.0.1"
      }
    }
  }

  network_device { bridge = "vmbr0" }
  operating_system { type = "l26" }
}
```

Where the settings come from:

- **`bios`, `machine`, `scsi_hardware`, `efi_disk`, `cpu.type`, ballooning**: the [Talos Proxmox guide](https://docs.siderolabs.com/talos/v1.14/platform-specific-installations/virtualized-platforms/proxmox.md) recommends `ovmf` + 4MB EFI disk, `q35`, CPU type `host`, ballooning disabled, and VirtIO SCSI. It warns against "VirtIO SCSI Single", which "causes bootstrap hangs". In the provider, `virtio-scsi-pci` is "VirtIO SCSI" and `virtio-scsi-single` is the one to avoid ([vm docs](https://github.com/bpg/terraform-provider-proxmox/blob/main/docs/resources/virtual_environment_vm.md)).
- **`initialization.ip_config`**: the provider's cloud-init block. Jonas uses it to give each node its static IP ([post 2](https://jonashietala.se/blog/2026/05/22/talos_linux_on_proxmox_with_terraform)).
- **Jonas's VMs differ**: they use `x86-64-v2-AES` and a `virtio0` disk. The Talos guide's recommendations win here.

**Unverified:** I haven't checked whether the `ovmf`/`efi_disk` combination boots the `nocloud` raw image the same way the Talos guide's ISO does. Jonas's VMs use the provider defaults (SeaBIOS). If UEFI causes trouble, drop `bios`/`efi_disk`.

### Sizing

For now, all three VMs share one host (i5-8500T, 6 cores, 16GB RAM, 1TB SSD):

| | Per node (×3 on one host) | Why |
| --- | --- | --- |
| CPU | 2 cores (6 vCPU total, matching the host's 6 cores) | The Talos control-plane **minimum** is 2. 4 is recommended ([system requirements](https://docs.siderolabs.com/talos/v1.14/getting-started/system-requirements.md)) |
| RAM | 4.5GB (13.5GB total, leaving ~2.5GB for Proxmox) | Talos recommends 4GiB+ for control planes. Each node also runs workloads, so this is tight |
| System disk | 50GB | Above the 10GiB minimum and Jonas's 40GB suggestion for real workloads. Talos recommends 100GiB ([system requirements](https://docs.siderolabs.com/talos/v1.14/getting-started/system-requirements.md)), which doesn't fit three times on one 1TB SSD next to Longhorn |
| Longhorn disk | 200GB (600GB total) | With 3 replicas on 3 nodes, about 200GB is usable cluster-wide. All replicas sit on the same physical SSD until the other hosts exist |

These numbers are a starting point for the single-host phase, and the right sizing is an [open question](/kubernetes/migration#open-questions). When hosts `.2` and `.3` arrive, each VM can grow to roughly 4 cores and 12GB with a much larger Longhorn disk.

The Longhorn disk is a **separate virtual disk**, not a partition on the system disk. The Talos Longhorn guide selects a non-system disk with a `UserVolumeConfig` ([guide](https://docs.siderolabs.com/kubernetes-guides/csi/longhorn.md)).

### Secrets and state

Following Jonas ([post 4](https://jonashietala.se/blog/2026/05/31/sops_age_and_sealed_secrets)):

- **Proxmox API token.** Jonas keeps his Proxmox credentials in a SOPS-encrypted `secrets.auto.tfvars`. I keep the token in `terraform/secrets.sops.yaml` (key `proxmox_api_token`). The `tf::apply` recipe passes it to Terraform as `TF_VAR_proxmox_api_token`, so the plaintext never touches the disk.
- **Terraform state.** The state is committed only as `terraform.tfstate.sops.json`. `tf::apply` decrypts it for the run and re-encrypts it in a shell `trap`, even if `apply` fails, which is Jonas's pattern ([post 3](https://jonashietala.se/blog/2026/05/28/just_command_runner_documentation)).

See [SOPS](/kubernetes/sops) and the [justfile](/kubernetes/getting-started/bootstrap#the-justfile).

## Local tools

- `terraform`, `topf` (with `sops` on `PATH`, since topf shells out to it), `talosctl` (debugging and `upgrade-k8s`)
- `kubectl`, `helm`, `helmfile`, `flux`
- `sops`, `gpg` (YubiKey), `age`
- `just`
- `k9s`, `kubectx`, `kustomize`
