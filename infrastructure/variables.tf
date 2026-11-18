variable "proxmox_api_token" {
  description = "Proxmox API token, \"terraform@pve!provider=<uuid>\". Comes from secrets.sops.yaml via TF_VAR_proxmox_api_token."
  type        = string
  sensitive   = true
}

variable "proxmox_host" {
  description = "IP of the Proxmox host"
  type        = string
}

variable "proxmox_endpoint" {
  description = "Proxmox API URL"
  type        = string
}

variable "proxmox_node" {
  description = "Proxmox node name (`hostname` on the Proxmox host)"
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
    ip               = string # CIDR, e.g. 10.0.11.1/16
    cores            = number
    memory_mb        = number
    system_disk_gb   = number
    longhorn_disk_gb = number
  }))
}
