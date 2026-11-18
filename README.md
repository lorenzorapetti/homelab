# homelab

My homelab: a Talos Linux Kubernetes cluster on Proxmox, managed with Terraform, [topf](https://github.com/postfinance/topf) and Flux. Full docs live in [`docs/`](docs/), a Docusaurus site. Start at [`docs/docs/kubernetes/intro.md`](docs/docs/kubernetes/intro.md).

## Layout

| Path | What |
| --- | --- |
| `infrastructure/` | Terraform (`bpg/proxmox`): the Talos VMs on Proxmox |
| `talos/` | Talos config for topf: cluster, patches, schematic, SOPS-encrypted secrets bundle |
| `kubernetes/` | Manifests Flux syncs into the cluster |
| `kubernetes_old/` | The previous k3s cluster's manifests, kept for reference while migrating |
| `docker/` | Docker Compose stacks outside the cluster |
| `docs/` | Documentation site |
| `justfile`, `*/mod.just` | Task runner |
| `devenv.nix` | Every CLI tool the repo needs |

## Getting started

Tools come from [devenv](https://devenv.sh), not from whatever is on `PATH`:

```bash
devenv shell          # terraform, sops, gpg, age, just, talosctl, topf, kubectl, yq
just                  # list recipes
```

Secrets are SOPS-encrypted (see `.sops.yaml`) to a GPG key on a YubiKey, plus an age key for Flux. Decrypting anything needs a YubiKey (PIN + touch).

### Proxmox VMs

```bash
just tf::init
just tf::plan
just tf::apply        # decrypts the API token + state, re-encrypts state on exit
```

The Proxmox API token lives in `infrastructure/secrets.sops.yaml` and the state in `infrastructure/terraform.tfstate.sops.json`. Neither is ever written to disk in plaintext between runs. See [Deploying the infrastructure](docs/docs/kubernetes/getting-started/deploying-the-infrastructure.md), which has the step-by-step procedure.

### Talos

```bash
just talos::create    # secrets bundle (once), diff + apply, bootstrap etcd, talosconfig/kubeconfig
just talos::diff      # what `just talos::apply` would change
```

`devenv shell` points `TALOSCONFIG` and `KUBECONFIG` at the generated (gitignored) files. See [Install Talos](docs/docs/kubernetes/getting-started/install-talos.md).
