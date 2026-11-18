# Non-secret values. The API token lives in secrets.sops.yaml.

proxmox_host     = "10.0.10.1"
proxmox_endpoint = "https://10.0.10.1:8006/"
proxmox_node     = "hecate"
vm_datastore     = "local-lvm"
image_datastore  = "local"
bridge           = "vmbr0"

talos_version      = "1.14.5"
talos_schematic_id = "88d1f7a5c4f1d3aba7df787c448c1d3d008ed29cfb34af53fa0df4336a56040b"

gateway = "10.0.0.1"

# Single-host phase: all three VMs share one i5-8500T (6 cores, 16GB RAM, 1TB SSD).
nodes = {
  "talos-1" = { ip = "10.0.11.1/16", cores = 2, memory_mb = 4608, system_disk_gb = 50, longhorn_disk_gb = 200 }
  "talos-2" = { ip = "10.0.11.2/16", cores = 2, memory_mb = 4608, system_disk_gb = 50, longhorn_disk_gb = 200 }
  "talos-3" = { ip = "10.0.11.3/16", cores = 2, memory_mb = 4608, system_disk_gb = 50, longhorn_disk_gb = 200 }
}
