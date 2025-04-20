---
sidebar_position: 1
sidebar_label: Introduction
---

# Flux

[Flux](https://fluxcd.io/) is a GitOps tool for Kubernetes. It allows you to manage your Kubernetes resources using Git as the source of truth. With Flux, you can automate the deployment of your applications and manage your Kubernetes cluster in a declarative way.

When you first create the cluster, Flux will bootstrap all the objects declared in the [`kubernetes`](https://github.com/lorenzorapetti/homelab/tree/main/kubernetes) folder.

## Install

Follow the [Install k3s](/kubernetes/getting-started/install-k3s#kubectl-and-utilities) section to install the Flux CLI.

### Existing repo with the Flux manifests

If you have a repo with the Flux manifests already present, you only need to apply them to the cluster:

```bash
kubectl apply -k kubernetes/apps/flux-system
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
