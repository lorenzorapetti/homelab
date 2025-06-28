---
sidebar_position: 1
sidebar_label: Introduction
---

# Flux

[Flux](https://fluxcd.io/) is a GitOps tool for Kubernetes. It allows you to manage your Kubernetes resources using Git as the source of truth. With Flux, you can automate the deployment of your applications and manage your Kubernetes cluster in a declarative way.

When you first create the cluster, Flux will bootstrap all the objects declared in the [`kubernetes`](https://github.com/lorenzorapetti/homelab/tree/main/kubernetes) folder.

## Installation

Follow the [Install k3s](/kubernetes/getting-started/install-k3s#kubectl-and-utilities) section to install the Flux CLI.

### Existing repo with the Flux manifests

If you have a repo with the Flux manifests already present and you saved the private key secret, you first need to apply the secret to the cluster (I saved mine in 1password):

```bash
kubectl create ns flux-system && op document get --vault Homelab "Flux Key" | kubectl apply -f -
```

Then, you can apply the Flux manifests:

:::warning

Remember to [apply the SOPS secret](/kubernetes/sops) first!

:::

:::warning

Make sure you use the `-k` flag instead of `-f` to tell Kubernetes to use the `kustomization.yaml` file.

:::

```bash
kubectl apply -k kubernetes/cluster/flux-system
```

### Existing repo without the Flux manifests

If you have an existing repo but don't have the Flux manifests, you can bootstrap Flux with the following command:

```bash
flux bootstrap git \
  --url=ssh://git@github.com/lorenzorapetti/homelab.git \
  --branch=main \
  --path=kubernetes/cluster \
  --private-key-file=/Users/lorenzo/.ssh/id_ed25519
```

You have to add the `/Users/lorenzo/.ssh/id_ed25519.pub` ssh public key to your [GitHub account](https://github.com/settings/ssh/new).

### New repo

If you want to create a new repo, follow the [official guide](https://fluxcd.io/flux/installation/bootstrap/github/).
