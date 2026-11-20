# Terraform for the Proxmox VMs. Recipes run in infrastructure/.
#
# The Proxmox API token and the Terraform state are committed only SOPS-encrypted:
#   secrets.sops.yaml            -> TF_VAR_proxmox_api_token (env only, never on disk)
#   terraform.tfstate.sops.json  -> terraform.tfstate for the run, re-encrypted on exit
# Decrypting needs the YubiKey (PIN + touch).

[doc("terraform init (no secrets needed)")]
init *args:
    terraform init {{ args }}

[doc("terraform plan")]
plan *args: (_run "plan" args)

[doc("terraform apply; state is re-encrypted on exit, even if apply fails")]
apply *args: (_run "apply" args)

[confirm("Destroy all Talos VMs?")]
[doc("terraform destroy")]
destroy *args: (_run "destroy" args)

[doc("terraform output")]
output *args: (_run "output" args)

[private]
_run command *args:
    #!/usr/bin/env bash
    set -euo pipefail
    umask 077

    if [[ -e terraform.tfstate ]]; then
      echo "error: plaintext terraform.tfstate already exists (an earlier run was interrupted?)." >&2
      echo "Encrypt it into terraform.tfstate.sops.json, or delete it if the .sops.json is current." >&2
      exit 1
    fi

    TF_VAR_proxmox_api_token="$(sops decrypt --extract '["proxmox_api_token"]' secrets.sops.yaml)"
    export TF_VAR_proxmox_api_token

    if [[ -f terraform.tfstate.sops.json ]]; then
      sops decrypt --input-type json --output-type json terraform.tfstate.sops.json > terraform.tfstate
    fi

    reencrypt() {
      # `plan` against an empty state never writes one.
      [[ -f terraform.tfstate ]] || return 0
      if sops encrypt --filename-override terraform.tfstate.sops.json \
          --input-type json --output-type json terraform.tfstate > terraform.tfstate.sops.json.tmp; then
        mv terraform.tfstate.sops.json.tmp terraform.tfstate.sops.json
        rm -f terraform.tfstate terraform.tfstate.backup
      else
        rm -f terraform.tfstate.sops.json.tmp
        echo "error: re-encrypting the state failed; plaintext terraform.tfstate kept so nothing is lost." >&2
        return 1
      fi
    }
    trap reencrypt EXIT

    # Split args on whitespace without letting bash strip quotes or expand globs, so
    # -target='proxmox_virtual_environment_vm.talos["talos-1"]' reaches terraform intact.
    read -ra tf_args <<< {{ quote(args) }}
    terraform {{ command }} "${tf_args[@]}"
