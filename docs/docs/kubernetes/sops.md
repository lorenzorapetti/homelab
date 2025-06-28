---
sidebar_position: 3
---

# SOPS

With [SOPS](https://github.com/getsops/sops) (Secrets OPerationS) I can save encrypted secrets directly in my Homelab repository.

## Installation

```sh
brew instal sops
```

### Create age key

If you don't already have a key, you can generate one with the following command:

```sh
age-keygen -o age.agekey
```

You have to keep this key safe, as it is used to encrypt and decrypt your secrets.

Then, you have to create a secret with the key:

```sh
cat age.agekey |
kubectl create secret generic sops-age \
--namespace=flux-system \
--from-file=age.agekey=/dev/stdin
```

### Existing age key

If you already have the key, you only need to create the secret (for example, I saved it in 1password):

```sh
op document get --vault=Homelab "AGE_KEY" |
kubectl create secret generic sops-age \
--namespace=flux-system \
--from-file=age.agekey=/dev/stdin
```

## Usage

To encrypt a secret, you need the public key, which you can find in the age.agekey file. You then encrypt the file with the following command:

```sh
sops --age=age1helqcqsh9464r8chnwc2fzj8uv7vr5ntnsft0tn45v2xtz0hpfwq98cmsg \
--encrypt --encrypted-regex '^(data|stringData)$' --in-place basic-auth.yaml
```

As you can see, typing out all these options is a bit cumbersome, so I created a `.sops.yaml` file in the root of my repository.

With this file, I can simplify the command to:

```sh
sops --in-place basic-auth.yaml
```
