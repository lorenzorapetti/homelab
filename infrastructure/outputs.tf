output "node_ips" {
  description = "Talos node IPs, for talosctl/topf"
  value       = { for name, node in var.nodes : name => split("/", node.ip)[0] }
}

output "vm_ids" {
  value = { for name, vm in proxmox_virtual_environment_vm.talos : name => vm.vm_id }
}
