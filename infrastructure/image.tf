# Talos nocloud disk image from the Image Factory, downloaded once to the Proxmox host.
# The factory serves the raw image as .raw.zst (and .raw.xz); zst matches decompression_algorithm.
resource "proxmox_download_file" "talos" {
  node_name               = var.proxmox_node
  datastore_id            = var.image_datastore
  content_type            = "iso"
  url                     = "https://factory.talos.dev/image/${var.talos_schematic_id}/v${var.talos_version}/nocloud-amd64.raw.zst"
  decompression_algorithm = "zst"
  file_name               = "talos-v${var.talos_version}-${substr(var.talos_schematic_id, 0, 8)}-nocloud-amd64.img"
  overwrite               = false
}
