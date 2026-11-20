# Non-secret values. The API token lives in secrets.sops.yaml.

# Proxmox cluster "underworld". The API endpoint is hecate's, but it serves both nodes.
proxmox_hosts = {
  hecate     = "10.0.10.1"
  persephone = "10.0.10.2"
}
proxmox_endpoint = "https://10.0.10.1:8006/"
vm_datastore     = "local-lvm"
image_datastore  = "local"
bridge           = "vmbr0"

talos_version      = "1.14.5"
talos_schematic_id = "88d1f7a5c4f1d3aba7df787c448c1d3d008ed29cfb34af53fa0df4336a56040b"

gateway = "10.0.0.1"

# Two hosts, both Intel N100 (4 cores, 16GB RAM, 1TB SSD).
# hecate: two VMs at 6.5GB leave ~2.4GB for Proxmox. persephone: talos-3 takes half
# the RAM, the rest stays free. A cores/memory change reboots the VM: apply one node
# at a time (drain first), with -target='proxmox_virtual_environment_vm.talos["<name>"]'.
nodes = {
  "talos-1" = { proxmox_node = "hecate", ip = "10.0.11.1/16", cores = 2, memory_mb = 6656, system_disk_gb = 50, longhorn_disk_gb = 200 }
  "talos-2" = { proxmox_node = "hecate", ip = "10.0.11.2/16", cores = 2, memory_mb = 6656, system_disk_gb = 50, longhorn_disk_gb = 200 }
  "talos-3" = { proxmox_node = "persephone", ip = "10.0.11.3/16", cores = 4, memory_mb = 8192, system_disk_gb = 50, longhorn_disk_gb = 200 }
}
