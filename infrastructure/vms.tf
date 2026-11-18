# proxmox_virtual_environment_vm, not proxmox_vm: the latter is an experimental rewrite
# the provider says "MUST NOT be used in production".
# One VM per Talos node. Settings follow the Talos Proxmox guide:
# q35, CPU type host, VirtIO SCSI (NOT "VirtIO SCSI single"), no ballooning, guest agent on.
resource "proxmox_virtual_environment_vm" "talos" {
  for_each = var.nodes

  name            = each.key
  node_name       = var.proxmox_node
  tags            = ["talos"]
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
    file_id      = proxmox_download_file.talos.id
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
}
