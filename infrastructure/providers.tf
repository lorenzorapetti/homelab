terraform {
  required_version = ">= 1.9"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.123.1"
    }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token # TF_VAR_proxmox_api_token, set by `just tf::*` from secrets.sops.yaml
  insecure  = true                  # Proxmox's self-signed certificate

  # Some operations (e.g. importing a disk from a downloaded file) go over SSH.
  # The SSH user's login shell on the Proxmox host must be POSIX (not fish).
  ssh {
    agent    = true
    username = "root"

    node {
      name    = var.proxmox_node
      address = var.proxmox_host
    }
  }
}
