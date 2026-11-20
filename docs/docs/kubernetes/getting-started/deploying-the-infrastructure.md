---
sidebar_position: 1
---

# Deploying the infrastructure

Talos is an immutable, API-managed OS: no SSH, no shell, no package manager. The infrastructure comes down to:

1. A Talos image (an Image Factory **schematic**) with the right system extensions.
2. One Proxmox VM per node, created by **Terraform** in `infrastructure/`, as Jonas does ([post 2](https://jonashietala.se/blog/2026/05/22/talos_linux_on_proxmox_with_terraform)).

The VMs boot into Talos **maintenance mode** with their final static IPs. [Install Talos](/kubernetes/getting-started/install-talos) then applies the machine config with topf.

All the commands below run inside `devenv shell` (see [Local tools](#local-tools)). The step-by-step procedure is in [Creating the VMs](#creating-the-vms). The sections before it explain the design.

## Nodes

| Node | IP | Role |
| --- | --- | --- |
| `talos-1` | `10.0.11.1` | control plane + workloads |
| `talos-2` | `10.0.11.2` | control plane + workloads |
| `talos-3` | `10.0.11.3` | control plane + workloads |

The VMs are spread over two Proxmox hosts: `talos-1` and `talos-2` on `hecate` (`10.0.10.1`), and `talos-3` on `persephone` (`10.0.10.2`). The cluster started the way Jonas did, with three control-plane VMs on one Proxmox host ([post 2](https://jonashietala.se/blog/2026/05/22/talos_linux_on_proxmox_with_terraform)). talos-3 moved to persephone when that host was added ([Adding a Proxmox host](#adding-a-proxmox-host)). Two hosts still give only **partial hardware redundancy**. If persephone dies, etcd keeps quorum on talos-1 and talos-2. If hecate dies, it takes two of the three etcd members with it, and the cluster stops. The Kubernetes API VIP is `10.0.11.10`, the gateway is `10.0.0.1`, and the netmask is `/16`. The full address plan is in the [network map](/kubernetes/intro#network-map).

## Talos image: the schematic

Talos images come from the [Image Factory](https://factory.talos.dev/). A schematic lists the system extensions, and the factory derives an ID from it ([Image Factory UI docs](https://docs.siderolabs.com/talos/v1.14/platform-specific-installations/use-the-image-factory-ui.md)). The same ID gives you the disk image Terraform boots and the installer image Talos installs and upgrades from.

`talos/schematic.yaml`:

```yaml
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/iscsi-tools        # Longhorn: iscsid + iscsiadm
      - siderolabs/qemu-guest-agent   # Proxmox guest agent
      - siderolabs/util-linux-tools   # Longhorn: fstrim
```

- **`qemu-guest-agent`** lets Proxmox shut the VM down cleanly. Only enable the Proxmox guest agent option if the image includes it ([Talos Proxmox guide](https://docs.siderolabs.com/talos/v1.14/platform-specific-installations/virtualized-platforms/proxmox.md)).
- **`iscsi-tools` and `util-linux-tools`** are required by Longhorn on every node ([Talos Longhorn guide](https://docs.siderolabs.com/kubernetes-guides/csi/longhorn.md), [Longhorn Talos page](https://longhorn.io/docs/latest/advanced-resources/os-distro-specific/talos-linux-support/)). Jonas notes the same in post 2. See [Storage: Longhorn](/kubernetes/storage-longhorn).

The schematic is already submitted. Its ID is **`88d1f7a5c4f1d3aba7df787c448c1d3d008ed29cfb34af53fa0df4336a56040b`**, and it is set as `talos_schematic_id` in `infrastructure/variables.auto.tfvars`. The factory returned it for a `POST /schematics` with this file. The extensions are listed alphabetically, the same order the factory normalises them to.

topf reads this file directly with `schematicId: "@schematic.yaml"` and computes the ID locally ([topf configuration](https://github.com/postfinance/topf/blob/main/docs/configuration.md#schematic-reference-resolution)). After changing the extensions, submit the new schematic and copy the printed ID into the tfvars ([docs](https://github.com/postfinance/topf/blob/main/docs/commands/schematic-ids.md)):

```bash
cd talos && topf --submit-to-factory schematic-ids
```

## VMs with Terraform

The Terraform lives in `infrastructure/`, as in Jonas's repo:

| File | What it holds |
| --- | --- |
| `providers.tf` | `bpg/proxmox` and the provider block |
| `variables.tf` | Variable declarations |
| `variables.auto.tfvars` | Every non-secret value: Proxmox hosts, datastores, bridge, Talos version, schematic ID, and the node table (with each VM's Proxmox host) |
| `image.tf` | The Talos image download, one per Proxmox host that runs a VM |
| `vms.tf` | The three VMs |
| `outputs.tf` | Node IPs and VM IDs |
| `mod.just` | `just tf::init`, `tf::plan`, `tf::apply`, `tf::destroy`, `tf::output` |
| `secrets.sops.yaml` | The Proxmox API token (SOPS) |
| `terraform.tfstate.sops.json` | The state (SOPS) |

### Provider

Jonas uses [`bpg/proxmox`](https://registry.terraform.io/providers/bpg/proxmox/latest) 0.95.0 (with `siderolabs/talos` for config). I use only `bpg/proxmox`, pinned to **v0.123.1**, because topf handles everything Talos.

```hcl
provider "proxmox" {
  endpoint  = var.proxmox_endpoint      # https://10.0.10.1:8006/
  api_token = var.proxmox_api_token     # "terraform@pve!provider=<uuid>"
  insecure  = true                      # Proxmox's self-signed certificate

  ssh {
    agent    = true
    username = "root"
    dynamic "node" {                    # one per Proxmox host
      for_each = var.proxmox_hosts      # { hecate = "10.0.10.1", persephone = "10.0.10.2" }
      content {
        name    = node.key
        address = node.value
      }
    }
  }
}
```

Any node of a Proxmox cluster serves the API for the whole cluster, so `endpoint` stays on hecate.

These are the provider arguments documented in the [provider docs](https://github.com/bpg/terraform-provider-proxmox/blob/main/docs/index.md). Jonas used username/password and says an API token would be better ([post 2](https://jonashietala.se/blog/2026/05/22/talos_linux_on_proxmox_with_terraform)). SSH is "only required" for a few operations, including disk imports from a local file. Importing with `import_from` goes through the API instead ([When is SSH required?](https://github.com/bpg/terraform-provider-proxmox/blob/main/docs/index.md)). Jonas's disk import broke when his Proxmox login shell was fish, so the SSH user on the Proxmox hosts must use a POSIX shell. The explicit `ssh.node` block keeps the provider from guessing the host's SSH address.

### Image

```hcl
resource "proxmox_download_file" "talos" {
  for_each                = toset([for node in values(var.nodes) : node.proxmox_node])
  node_name               = each.key
  datastore_id            = var.image_datastore   # "local"
  content_type            = "iso"
  url                     = "https://factory.talos.dev/image/${var.talos_schematic_id}/v${var.talos_version}/nocloud-amd64.raw.zst"
  decompression_algorithm = "zst"
  file_name               = "talos-v${var.talos_version}-${substr(var.talos_schematic_id, 0, 8)}-nocloud-amd64.img"
  overwrite               = false
}
```

This is adapted from Jonas's resource ([post 2](https://jonashietala.se/blog/2026/05/22/talos_linux_on_proxmox_with_terraform)). It uses the **`nocloud`** image, so the static IP comes from Proxmox cloud-init ([Talos nocloud docs](https://docs.siderolabs.com/talos/v1.14/platform-specific-installations/cloud-platforms/nocloud.md)). Differences from Jonas:

- **`.raw.zst`, not `.raw.xz`.** Jonas's URL ends in `.raw.xz` while his `decompression_algorithm` is `zst`. The factory serves both (`HEAD` returns 200 for each), and the provider can't decompress xz (it accepts `gz`, `lzo`, `zst` or `bz2`), so the URL uses `.raw.zst` ([download_file docs](https://github.com/bpg/terraform-provider-proxmox/blob/main/docs/resources/virtual_environment_download_file.md)).
- **`proxmox_download_file`.** In v0.123 `proxmox_virtual_environment_download_file` is deprecated, and `terraform validate` warns it "will be removed in v1.0". The arguments are the same.
- **The schematic is in the file name**, so changing extensions downloads a new image instead of reusing an old file with the same Talos version.
- **The Talos version is 1.14.5**, matching `talosctl` in the devenv shell.
- **One download per host.** `local` is per-node storage, so a VM can only be built from an image on its own host. A `moved` block mapped the original single image to `talos["hecate"]`.

Compressed images must be attached with `file_id`, not `import_from` ([vm docs](https://github.com/bpg/terraform-provider-proxmox/blob/main/docs/resources/virtual_environment_vm.md)).

### VMs

`vms.tf`, with each node's values taken from the `nodes` map in `variables.auto.tfvars`:

```hcl
resource "proxmox_virtual_environment_vm" "talos" {
  for_each        = var.nodes
  name            = each.key
  node_name       = each.value.proxmox_node    # "hecate" or "persephone"
  migrate         = true                       # a node_name change live-migrates the VM
  timeout_migrate = 3600
  on_boot         = true
  stop_on_destroy = true

  bios    = "ovmf"
  machine = "q35"
  efi_disk {
    datastore_id = var.vm_datastore
    type         = "4m"
  }

  agent { enabled = true }                     # needs the qemu-guest-agent extension
  cpu {
    cores = each.value.cores                   # 2 (talos-3: 4)
    type  = "host"
  }
  memory {
    dedicated = each.value.memory_mb           # 6656 (talos-3: 8192)
    floating  = 0                              # no ballooning
  }

  scsi_hardware = "virtio-scsi-pci"            # NOT virtio-scsi-single

  # System disk: Talos (EPHEMERAL holds container images, logs, etcd)
  disk {
    datastore_id = var.vm_datastore
    file_id      = proxmox_download_file.talos[each.value.proxmox_node].id
    interface    = "scsi0"
    size         = each.value.system_disk_gb   # 50
    discard      = "on"
    ssd          = true
  }

  # Data disk: Longhorn (UserVolumeConfig "longhorn")
  disk {
    datastore_id = var.vm_datastore
    interface    = "scsi1"
    size         = each.value.longhorn_disk_gb # 200
    discard      = "on"
    ssd          = true
  }

  boot_order = ["scsi0"]

  initialization {
    datastore_id = var.vm_datastore
    ip_config {
      ipv4 {
        address = each.value.ip                # e.g. 10.0.11.1/16, flat 10.0.0.0/16 LAN
        gateway = var.gateway                  # 10.0.0.1
      }
    }
  }

  network_device { bridge = var.bridge }       # vmbr0
  operating_system { type = "l26" }

  # Talos upgrades itself in place; a new image must not recreate the VMs
  lifecycle { ignore_changes = [disk[0].file_id] }
}
```

Where the settings come from:

- **`bios`, `machine`, `scsi_hardware`, `efi_disk`, `cpu.type`, ballooning**: the [Talos Proxmox guide](https://docs.siderolabs.com/talos/v1.14/platform-specific-installations/virtualized-platforms/proxmox.md) recommends `ovmf` + 4MB EFI disk, `q35`, CPU type `host`, ballooning disabled, and VirtIO SCSI. It warns against "VirtIO SCSI Single", which "causes bootstrap hangs". In the provider, `virtio-scsi-pci` is "VirtIO SCSI" and `virtio-scsi-single` is the one to avoid ([vm docs](https://github.com/bpg/terraform-provider-proxmox/blob/main/docs/resources/virtual_environment_vm.md)). `floating = 0` disables the balloon device.
- **`initialization.ip_config`**: the provider's cloud-init block. Jonas uses it to give each node its static IP ([post 2](https://jonashietala.se/blog/2026/05/22/talos_linux_on_proxmox_with_terraform)).
- **`ignore_changes = [disk[0].file_id]`**: the system disk is only created from the image. Without this, a new `talos_version` or `talos_schematic_id` renames the image file, and `terraform plan` replaces all three VMs (`file_id … # forces replacement`). With it, only the image file is re-downloaded ([Upgrades](/kubernetes/upgrades)). To rebuild a VM from the new image on purpose, use `just tf::apply -replace='proxmox_virtual_environment_vm.talos["talos-1"]'`.
- **`migrate = true`**: without it, a new `node_name` destroys the VM and creates it again on the other host, Longhorn disk included. With it, provider v0.123.1 calls the Proxmox migrate API with `online=1` and `with-local-disks=1`: a live migration that copies the disks over. See [Adding a Proxmox host](#adding-a-proxmox-host).
- **`proxmox_virtual_environment_vm`, not `proxmox_vm`.** v0.123 also ships `proxmox_vm`, but its schema describes it as an experimental rewrite that "MUST NOT be used in production".
- **Jonas's VMs differ**: they use `x86-64-v2-AES` and a `virtio0` disk. The Talos guide's recommendations win here. With VirtIO SCSI, the system disk is `/dev/sda` and the Longhorn disk is `/dev/sdb` (Jonas's `/dev/vda` doesn't apply).

**UEFI works.** Jonas's VMs use the provider defaults (SeaBIOS), so it wasn't certain that `ovmf` + `efi_disk` would boot the `nocloud` raw image the way the Talos guide's ISO does. It does: on the first `apply` (2026-11-18, Talos 1.14.5, PVE 9), all three VMs booted straight into maintenance mode with their cloud-init IPs. No SeaBIOS fallback is needed.

### Sizing

Both hosts are Intel N100s (4 cores, 16GB RAM, 1TB SSD):

| | `talos-1`, `talos-2` (hecate) | `talos-3` (persephone) | Why |
| --- | --- | --- | --- |
| CPU | 2 cores each | 4 cores | The Talos control-plane **minimum** is 2, and 4 is recommended ([system requirements](https://docs.siderolabs.com/talos/v1.14/getting-started/system-requirements.md)). hecate's two VMs use all 4 of its cores. talos-3 gets all of persephone's |
| RAM | 6.5GB each (13GB, leaving ~2.4GB for Proxmox) | 8GB (half the host) | Talos recommends 4GiB+ for control planes, and every node also runs workloads. persephone keeps 8GB free |
| System disk | 50GB | 50GB | Above the 10GiB minimum and Jonas's 40GB suggestion for real workloads. Talos recommends 100GiB ([system requirements](https://docs.siderolabs.com/talos/v1.14/getting-started/system-requirements.md)). The system disks are about 30% used so far, so 50GB is enough for now |
| Longhorn disk | 200GB | 200GB | Volumes have 2 replicas, so about 300GB is usable cluster-wide |

Until 2026-11-21, all three VMs ran on hecate with 2 cores and 4.5GB each. That was tight, and it was [open question 3](/kubernetes/migration#open-questions). Resizing reboots the VM, so it's done one node at a time ([Adding a Proxmox host](#adding-a-proxmox-host)).

The Longhorn disk is a **separate virtual disk**, not a partition on the system disk. The Talos Longhorn guide selects a non-system disk with a `UserVolumeConfig` ([guide](https://docs.siderolabs.com/kubernetes-guides/csi/longhorn.md)).

### Secrets and state

Following Jonas ([post 4](https://jonashietala.se/blog/2026/05/31/sops_age_and_sealed_secrets)):

- **Proxmox API token.** Jonas keeps his Proxmox credentials in a SOPS-encrypted `secrets.auto.tfvars`. I keep the token in `infrastructure/secrets.sops.yaml` (key `proxmox_api_token`). Every `just tf::*` recipe except `init` passes it to Terraform as `TF_VAR_proxmox_api_token`, so the plaintext never touches the disk.
- **Terraform state.** The state is committed only as `infrastructure/terraform.tfstate.sops.json`. The recipes decrypt it for the run and re-encrypt it in a shell `trap`, even if `apply` fails, which is Jonas's pattern ([post 3](https://jonashietala.se/blog/2026/05/28/just_command_runner_documentation)). If re-encryption fails, the plaintext state is kept rather than deleted. The next run refuses to start while a plaintext `terraform.tfstate` exists. `.gitignore` excludes `*.tfstate`.

See [SOPS](/kubernetes/sops) and the [justfile](/kubernetes/getting-started/bootstrap#the-justfile).

## Creating the VMs

From an empty Proxmox host to three VMs in maintenance mode. Steps 1–4 are one-time setup. After that, every change is `just tf::plan` / `just tf::apply`.

### 0. Prerequisites

- `devenv shell` at the repo root, and a YubiKey plugged in (`gpg --card-status` shows the card).
- Your SSH key in the ssh-agent and in `root@10.0.10.1`'s `authorized_keys`. Check with `ssh -o BatchMode=yes root@10.0.10.1 true`. Root's login shell must not be fish (see [Provider](#provider)).
- `variables.auto.tfvars` matches the hosts: `proxmox_hosts` lists every Proxmox node by hostname, datastores `local-lvm` (VM disks) and `local` (with the ISO content type), bridge `vmbr0`.

### 1. Proxmox role

In the Proxmox UI (`https://10.0.10.1:8006/`, logged in as root with the Linux PAM realm): **Datacenter → Permissions → Roles → Create**, name `Terraform`. The quickest way is to paste this into **hecate → Shell** instead:

```bash
# Proxmox VE 9. On PVE 8, replace VM.GuestAgent.Audit with VM.Monitor.
pveum role add Terraform -privs "Datastore.AllocateSpace,Datastore.AllocateTemplate,Datastore.Audit,SDN.Audit,SDN.Use,Sys.Audit,Sys.Modify,VM.Allocate,VM.Audit,VM.Config.CDROM,VM.Config.CPU,VM.Config.Cloudinit,VM.Config.Disk,VM.Config.HWType,VM.Config.Memory,VM.Config.Network,VM.Config.Options,VM.Console,VM.Migrate,VM.PowerMgmt,VM.GuestAgent.Audit"
```

The provider docs' example role also grants user, permission and pool management. The provider calls that list "likely too permissive for most use cases" ([provider docs](https://github.com/bpg/terraform-provider-proxmox/blob/main/docs/index.md)). This narrower role covers downloading the image and creating, updating and destroying VMs. `SDN.Audit`/`SDN.Use` must stay: without them, PVE hides the bridges and the provider can't resolve the node's address. `VM.Migrate` is for moving VMs between hosts. On PVE 9 this list was enough for `plan`, the image download, creating the VMs, and live-migrating talos-3 to persephone. `destroy` hasn't been tried yet. If a run fails with `403` / "Permission check failed", the error names the missing privilege. Add it under **Roles → Terraform → Edit**.

### 2. User and permission

- **Datacenter → Permissions → Users → Add**: user name `terraform`, realm *Proxmox VE authentication server* (`pve`). No password is needed.
- **Datacenter → Permissions → Add → User Permission**: path `/`, user `terraform@pve`, role `Terraform`, *Propagate* ticked.

### 3. API token, straight into SOPS

**Datacenter → Permissions → API Tokens → Add**: user `terraform@pve`, token ID `provider`, **untick _Privilege Separation_**, so the token gets exactly the user's rights. Otherwise the role would have to be granted to the token itself. Copy the *Secret*, which Proxmox shows only once.

Pipe it straight into sops, so the plaintext never touches the disk. `read -s` keeps it out of the shell history. Encrypting needs only public keys, so no YubiKey touch:

```bash
cd infrastructure
read -rs SECRET   # paste the token secret, then Enter
printf 'proxmox_api_token: "terraform@pve!provider=%s"\n' "$SECRET" \
  | sops encrypt --filename-override secrets.sops.yaml > secrets.sops.yaml
unset SECRET
sops decrypt --extract '["proxmox_api_token"]' secrets.sops.yaml | cut -d= -f1   # touch: prints terraform@pve!provider
```

`--filename-override` makes sops pick creation rule 2 in [`.sops.yaml`](/kubernetes/sops#sopsyaml): the GPG key plus the age key, whole file.

### 4. Init, plan, apply

```bash
just tf::init    # providers only, no secrets
just tf::plan    # touch the YubiKey: 4 to add (the image + 3 VMs)
just tf::apply   # touch again, then type "yes"
```

`apply` downloads the Talos image to `hecate` (about 235MB compressed) and creates `talos-1..3`. The state comes back as `terraform.tfstate.sops.json`, even if `apply` fails.

### 5. Check the VMs

- **Console.** **hecate → talos-N → Console** shows the Talos dashboard in stage *Maintenance*, with the node's `10.0.11.N` IP.
- **Disks.** Each node shows the system disk as `sda` (`54 GB`, which is 50GiB in decimal units) and the Longhorn disk as `sdb` (`215 GB`, 200GiB). Both report transport `virtio` and model `QEMU HARDDISK`. The cloud-init drive shows up as `sr0`. The Talos install disk is therefore `/dev/sda`:

  ```bash
  for n in 1 2 3; do talosctl get disks --insecure -n 10.0.11.$n; done
  ```

- **Idempotency.** A second run must change nothing. `-detailed-exitcode` exits `0` for no changes and `2` for a diff:

  ```bash
  just tf::plan -detailed-exitcode
  ```

### 6. Commit

Commit `infrastructure/secrets.sops.yaml` and `infrastructure/terraform.tfstate.sops.json`. `.gitignore` excludes the plaintext `*.tfstate`. Next: [Install Talos](/kubernetes/getting-started/install-talos).

## Adding a Proxmox host

How `persephone` (`10.0.10.2`) joined on 2026-11-20/21 and took `talos-3`. A migration keeps the VM's identity: the same node, IP, etcd member and Longhorn data. That is much simpler than replacing the node.

### The Proxmox cluster

- **Install.** PVE 9 with the same layout as hecate: `local` (ISO content) plus `local-lvm` (thin LVM), `vmbr0` on the LAN NIC, static `10.0.10.2/16`, gateway `10.0.0.1`, DNS `10.0.1.30`. Root's login shell stays bash ([Provider](#provider)). It joined the tailnet, but not as a subnet router ([Remote access](/kubernetes/remote-access-tailscale)).
- **Cluster.** `pvecm create underworld` on hecate, then `pvecm add 10.0.10.1` on the new, empty host. hecate's running VMs weren't affected, and the `Terraform` role, user and token in `/etc/pve` apply cluster-wide.
- **No QDevice, on purpose.** With two votes, losing either host leaves the other without quorum, so `/etc/pve` turns read-only and VMs can't be started or changed until the host is back. A QDevice (`corosync-qnetd` on a third machine) would fix that. For a staging cluster it isn't worth it.

### Terraform

`proxmox_hosts` maps each host to its IP, and each entry in `nodes` names its `proxmox_node`. Changing a VM's `proxmox_node` live-migrates it (`migrate = true`, see [VMs](#vms)).

### Moving a VM

1. Drain the node: `kubectl drain talos-3 --ignore-daemonsets --delete-emptydir-data`. Longhorn's instance-manager PDB blocks the drain until the node's volumes have detached. `kubectl drain` retries every 5s until then.
2. Change its `proxmox_node` in `variables.auto.tfvars`, then `just tf::plan`. The plan must show the VM **updated in place** (`node_name`), never replaced.
3. `just tf::apply`, then `kubectl uncordon talos-3`.

As built (talos-3, hecate → persephone): the migration task took about 6 minutes. The VM kept running, and etcd and Longhorn didn't notice. The apply ran before the drain, which turned out not to matter for a live migration.

**The migration fills thin disks.** The copy writes every block, so the target's thin volumes come out 100% allocated (250GB instead of ~15GB of real data). A trim inside the VM gives the space back. The `fstrim` DaemonSet in `kubernetes/apps/kube-system/fstrim` does this on every node when it starts and weekly after that ([Storage: Longhorn](/kubernetes/storage-longhorn)). The first manual trim of talos-3 took persephone's pool from 30.6% to 2.2%.

### Resizing VMs

A cores or memory change reboots the VM (the provider's `reboot_after_update` defaults to true). An untargeted apply would reboot all three at once and take etcd quorum down. So go one node at a time, waiting until the node is `Ready` and every Longhorn volume is `healthy` before the next:

```bash
kubectl drain talos-3 --ignore-daemonsets --delete-emptydir-data
just tf::apply -target='proxmox_virtual_environment_vm.talos["talos-3"]'
kubectl uncordon talos-3
kubectl -n longhorn-system get volumes.longhorn.io   # wait for every volume to be healthy
```

- **Single-instance CloudNativePG clusters block the drain.** Their `-primary` PDB allows 0 disruptions. For the drain, set `spec.nodeMaintenanceWindow: {inProgress: true, reusePVC: true}` on the `Cluster` with `kubectl patch`. CNPG then drops the PDB, and the database restarts on another node (minutes of downtime). Flux removes the field again at its next reconcile, because it isn't in git.
- **The API VIP moves.** While the node holding `10.0.11.10` reboots, `kubectl` briefly fails with TLS handshake timeouts until another control-plane node takes the VIP over.

## Local tools

The tools come from `devenv.nix` at the repo root. Run `devenv shell`, or `devenv shell -- just tf::plan`:

- `terraform` (from nixpkgs; `devenv.yaml` sets `allowUnfree` because of its BUSL licence)
- `sops`, `gnupg` (YubiKey), `age`
- `just`
- `talosctl` (debugging and `upgrade-k8s`)
- `topf`, which isn't in nixpkgs. `devenv.nix` installs the pinned upstream release binary (`topf_linux_amd64.tar.gz` from [GitHub releases](https://github.com/postfinance/topf/releases)). To bump it, change `version` and refresh `hash` with `nix store prefetch-file <url>`. topf shells out to `sops`, which is on `PATH` in the shell.
- `kubectl`, `yq`, `helm` (wrapped with the helm-diff plugin), `helmfile`, the `cilium` CLI and the `flux` CLI (`fluxcd`), for the [bootstrap](/kubernetes/getting-started/bootstrap)

`k9s`, `kubectx` and `kustomize` get added to `devenv.nix` when they're needed. Updating the tools is covered in [Upgrades](/kubernetes/upgrades#cli-tools).
