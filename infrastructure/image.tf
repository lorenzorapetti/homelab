# Talos nocloud disk image from the Image Factory, downloaded once to every Proxmox node
# that hosts a Talos VM: `local` is per-node storage, so a VM can only be (re)built from
# an image on its own node.
# The factory serves the raw image as .raw.zst (and .raw.xz); zst matches decompression_algorithm.
resource "proxmox_download_file" "talos" {
  for_each = toset([for node in values(var.nodes) : node.proxmox_node])

  node_name               = each.key
  datastore_id            = var.image_datastore
  content_type            = "iso"
  url                     = "https://factory.talos.dev/image/${var.talos_schematic_id}/v${var.talos_version}/nocloud-amd64.raw.zst"
  decompression_algorithm = "zst"
  file_name               = "talos-v${var.talos_version}-${substr(var.talos_schematic_id, 0, 8)}-nocloud-amd64.img"
  overwrite               = false
}

# Single-host era: the image was one un-keyed resource on hecate.
moved {
  from = proxmox_download_file.talos
  to   = proxmox_download_file.talos["hecate"]
}
