variable "proxmox_api_token" {
  description = "Proxmox API token, \"terraform@pve!provider=<uuid>\". Comes from secrets.sops.yaml via TF_VAR_proxmox_api_token."
  type        = string
  sensitive   = true
}

variable "proxmox_hosts" {
  description = "Proxmox cluster nodes: node name (`hostname` on the host) => IP, for the provider's SSH operations"
  type        = map(string)
}

variable "proxmox_endpoint" {
  description = "Proxmox API URL (any cluster node serves the whole cluster's API)"
  type        = string
}

variable "vm_datastore" {
  description = "Datastore for VM disks, EFI disks and cloud-init drives"
  type        = string
}

variable "image_datastore" {
  description = "Datastore (with `iso` content enabled) for the downloaded Talos image"
  type        = string
}

variable "bridge" {
  description = "Proxmox network bridge on the LAN"
  type        = string
}

variable "talos_version" {
  description = "Talos version of the boot image, without the leading v"
  type        = string
}

variable "talos_schematic_id" {
  description = "Image Factory schematic ID for talos/schematic.yaml"
  type        = string
}

variable "gateway" {
  description = "LAN gateway"
  type        = string
}

variable "nodes" {
  description = "Talos VMs, keyed by hostname"
  type = map(object({
    proxmox_node     = string # key of proxmox_hosts; changing it live-migrates the VM
    ip               = string # CIDR, e.g. 10.0.11.1/16
    cores            = number
    memory_mb        = number
    system_disk_gb   = number
    longhorn_disk_gb = number
  }))

  validation {
    condition     = alltrue([for node in values(var.nodes) : contains(keys(var.proxmox_hosts), node.proxmox_node)])
    error_message = "Every node's proxmox_node must be a key of proxmox_hosts."
  }
}
