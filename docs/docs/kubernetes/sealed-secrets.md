---
sidebar_position: 3
---

# Sealed Secrets

With Sealed Secrets I can save encrypted secrets directly in my Homelab repository.

## Installation

Sealed Secrets is composed by a controller and a client. The controller runs in the cluster and is responsible for decrypting the secrets. The client is used to encrypt the secrets before saving them in the repository.

You can install the client by following the [Install k3s](/kubernetes/getting-started/install-k3s#kubectl-and-utilities) section.

### Existing repository

If you already have a repository with sealed secrets and you saved the private key, you first need to apply it to the cluster (I saved mine in 1password):

```bash
op document get --vault=Homelab "Sealed Secrets Key" | kubectl apply -f -
```

Then you can follow the [Flux installation](/kubernetes/flux/intro.md#installation) to let Flux install the rest of the components from the git repo.

### New repository

If you want to create a new repository, follow the [official guide](https://github.com/bitnami-labs/sealed-secrets#installation). If you use Flux you can follow [their guide](https://fluxcd.io/flux/guides/sealed-secrets/#deploy-sealed-secrets-with-a-helmrelease).

## Usage

### Encrypting secrets with a public key

If you saved and applied the private key, you can use the public key to encrypt the secrets. You can find the public key in the `sealed-secrets-key` secret:

```bash
kubeseal --fetch-cert \
--controller-name=sealed-secrets-controller \
--controller-namespace=kube-system \
> pub-sealed-secrets.pem
```

Then you can use the public key to encrypt the secrets:

```bash
kubectl create secret generic my-secret \
  --dry-run=client \
  --from-literal=foo=bar \
  -o yaml | \
  kubeseal \
  --format=yaml \
  --cert=pub-sealed-secrets.pem \
  > my-secret.yaml
```

You can now safely store `my-secret.yaml` in your repository. The secret will be decrypted by the controller when it is applied to the cluster.

### Backup the private key

You can backup the private key by running the following command:

```bash
kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > key.yaml
```
