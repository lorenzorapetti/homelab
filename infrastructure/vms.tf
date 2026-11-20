# proxmox_virtual_environment_vm, not proxmox_vm: the latter is an experimental rewrite
# the provider says "MUST NOT be used in production".
# One VM per Talos node. Settings follow the Talos Proxmox guide:
# q35, CPU type host, VirtIO SCSI (NOT "VirtIO SCSI single"), no ballooning, guest agent on.
resource "proxmox_virtual_environment_vm" "talos" {
  for_each = var.nodes

  name      = each.key
  node_name = each.value.proxmox_node
  tags      = ["talos"]
  # A node_name change live-migrates the VM, local disks included, instead of recreating it.
  migrate         = true
  timeout_migrate = 3600 # ~250 GB of thin disks to copy over 1 GbE in the worst case
  on_boot         = true
  stop_on_destroy = true

  bios    = "ovmf"
  machine = "q35"
  efi_disk {
    datastore_id = var.vm_datastore
    type         = "4m"
  }

  agent {
    enabled = true # needs the qemu-guest-agent extension in the schematic
  }

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory_mb
    floating  = 0 # disables the balloon device
  }

  scsi_hardware = "virtio-scsi-pci"

  # System disk: the Talos image (EPHEMERAL holds container images, logs, etcd)
  disk {
    datastore_id = var.vm_datastore
    file_id      = proxmox_download_file.talos[each.value.proxmox_node].id
    interface    = "scsi0"
    size         = each.value.system_disk_gb
    discard      = "on"
    ssd          = true
  }

  # Separate virtual disk for Longhorn (selected later by a UserVolumeConfig)
  disk {
    datastore_id = var.vm_datastore
    interface    = "scsi1"
    size         = each.value.longhorn_disk_gb
    discard      = "on"
    ssd          = true
  }

  boot_order = ["scsi0"]

  # nocloud: Talos reads its static IP from the Proxmox cloud-init drive
  initialization {
    datastore_id = var.vm_datastore
    ip_config {
      ipv4 {
        address = each.value.ip
        gateway = var.gateway
      }
    }
  }

  network_device {
    bridge = var.bridge
  }

  operating_system {
    type = "l26"
  }

  # The system disk is only seeded from the image when the VM is created; Talos then
  # upgrades itself in place (`just talos::upgrade`). Without this, a new talos_version
  # or talos_schematic_id renames the image file and Terraform recreates every VM,
  # Longhorn disk included. To rebuild a VM from the new image on purpose:
  #   just tf::apply -replace='proxmox_virtual_environment_vm.talos["talos-1"]'
  lifecycle {
    ignore_changes = [disk[0].file_id]
  }
}
