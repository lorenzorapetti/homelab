# Talos machine config with topf. Recipes run in talos/.
#
# secrets.sops.yaml is the Talos secrets bundle, committed only SOPS-encrypted.
# Every topf command that reads it decrypts through sops + gpg, so the YubiKey
# must be plugged in (PIN + touch). Rendered configs, talosconfig and kubeconfig
# are gitignored.

export TALOSCONFIG := justfile_directory() / "talos" / "talosconfig"
export KUBECONFIG := justfile_directory() / "kubeconfig"

[doc("Generate secrets (once), apply config (diff + confirm), bootstrap etcd, write talosconfig/kubeconfig")]
create: _secrets && configs
    topf apply --auto-bootstrap

[doc("Write talosconfig and a 1-year admin kubeconfig from the secrets bundle")]
configs:
    #!/usr/bin/env bash
    set -euo pipefail
    umask 077
    topf talosconfig > "$TALOSCONFIG.tmp" && mv "$TALOSCONFIG.tmp" "$TALOSCONFIG"
    topf kubeconfig --validity 8760h > "$KUBECONFIG.tmp" && mv "$KUBECONFIG.tmp" "$KUBECONFIG"
    echo "wrote $TALOSCONFIG and $KUBECONFIG"

[doc("topf apply: shows the diff and asks before applying")]
apply *args:
    topf apply {{ args }}

[doc("Show what topf apply would change (exits 2 when there are changes)")]
diff *args:
    topf apply --dry-run {{ args }}

[doc("Upgrade Talos to talosVersion / schematic.yaml, one node at a time")]
upgrade *args:
    topf upgrade {{ args }}

[doc("Upgrade Kubernetes to kubernetesVersion from topf.yaml")]
upgrade-k8s:
    talosctl --nodes 10.0.11.1 upgrade-k8s --to "$(yq '.kubernetesVersion' topf.yaml)"

# --full=false wipes only STATE and EPHEMERAL: a full wipe would also erase the
# Talos install on sda, and the VMs have no other boot media.
[confirm("Reset ALL nodes to maintenance mode? This destroys the cluster.")]
[doc("Reset every node to maintenance mode (keeps the Talos install and the Longhorn disk)")]
reset:
    topf reset --full=false --confirm=false --wait-for-maintenance

# Generate the bundle if it's missing, then refuse to go on unless it's encrypted.
[private]
_secrets:
    #!/usr/bin/env bash
    set -euo pipefail
    umask 077
    topf secrets --confirm=false > /dev/null
    if [[ "$(sops filestatus secrets.sops.yaml)" != '{"encrypted":true}' ]]; then
      echo "error: talos/secrets.sops.yaml is NOT SOPS-encrypted. Don't commit it." >&2
      echo "Check the talos/ rule in .sops.yaml, then delete the file and run this again." >&2
      exit 1
    fi
