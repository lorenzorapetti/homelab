---
sidebar_position: 3
---

# SOPS

With [SOPS](https://github.com/getsops/sops) (Secrets OPerationS) I can save encrypted secrets directly in my homelab repository. Two keys are involved:

- **My GPG key, on two YubiKeys.** Both cards carry the *same* OpenPGP key, so there is a single fingerprint. Decrypting anything locally needs either YubiKey plus its PIN and a touch.
- **An age key, for Flux.** kustomize-controller decrypts `*.sops.yaml` in the cluster with a software key stored in the `flux-system/sops-age` Secret.

The age private key is itself committed to the repo, **encrypted only to the YubiKey GPG key**. Bootstrapping a new cluster therefore needs nothing but this repo and one YubiKey.

Jonas splits this work between SOPS (Talos and Terraform files) and Sealed Secrets (in-cluster secrets), because Sealed Secrets "can only manage secrets inside Kubernetes" ([post 4](https://jonashietala.se/blog/2026/05/31/sops_age_and_sealed_secrets)). Flux decrypts SOPS natively ([Flux SOPS guide](https://fluxcd.io/flux/guides/mozilla-sops/)), so I don't need Sealed Secrets.

## Why age for Flux and PGP for me

- **Flux can't use a hardware token.** Flux does support OpenPGP, but only with a secret key exported into a Kubernetes Secret: the guide generates the key with "no passphrase (`%no-protection`)", exports it with `gpg --export-secret-keys --armor`, and stores it under a `.asc` key ([Flux SOPS guide](https://fluxcd.io/flux/guides/mozilla-sops/)). A key that lives on a YubiKey can't be exported, so the cluster needs its own software key.
- **Flux and SOPS both recommend age for that key.** Flux says "It's recommended to use age over OpenPGP, if possible" ([Flux SOPS guide](https://fluxcd.io/flux/guides/mozilla-sops/)), and the SOPS docs say the same ([SOPS age docs](https://getsops.io/docs/usage/identities/age/)).
- **Any one recipient can decrypt.** SOPS encrypts each file's data key "with each of the master keys, such that if any of the master keys is available, the file can be decrypted" ([SOPS key groups](https://getsops.io/docs/usage/identities/key-groups/)). A file encrypted to the GPG key *and* the age key opens with either one.
- **Encrypting needs only public keys.** The age *private* key is never needed on the workstation.

## Workstation setup (NixOS + YubiKey)

SOPS calls `gpg`. `gpg` goes through `gpg-agent`, which starts **scdaemon** ("a daemon to manage smartcards", [GnuPG manual](https://www.gnupg.org/documentation/manuals/gnupg/Invoking-SCDAEMON.html)) to talk to the card. topf decrypts the Talos secrets by running the same `sops` binary ([source](https://github.com/postfinance/topf/blob/main/internal/sops/sops.go)), so it works the same way. NixOS config, per the [NixOS wiki](https://wiki.nixos.org/wiki/Yubikey):

```nix
services.pcscd.enable = true;
services.udev.packages = [ pkgs.yubikey-personalization ];
programs.gnupg.agent.enable = true;
```

The wiki notes that pcscd "sometimes conflicts with gpg-agent". The fix is `disable-ccid` in `~/.gnupg/scdaemon.conf`, which makes scdaemon use PC/SC (pcscd) instead of its built-in CCID driver ([scdaemon options](https://www.gnupg.org/documentation/manuals/gnupg/Scdaemon-Options.html)).

Day to day:

- **Finding the key.** Each encrypted file records its recipients' fingerprints in its `sops:` metadata, so `sops decrypt` / `sops edit` need no configuration. SOPS uses the `gpg` binary unless `SOPS_GPG_EXEC` names another one ([SOPS PGP docs](https://getsops.io/docs/usage/identities/pgp/)). New files get their recipients from `.sops.yaml`. The **public** key must be in the local keyring (`gpg --import`).
- **PIN and touch.** `pinentry` asks for the card PIN once, and gpg-agent caches it. With a touch policy enabled on the card's encryption key, every decryption waits for a touch. **Unverified:** the touch policy is set with Yubico's `ykman openpgp keys set-touch`. Check its `--help`.
- **The age key isn't kept locally.** If it's ever needed, `SOPS_AGE_KEY_CMD` can fetch it on demand through the YubiKey, e.g. `sops decrypt --extract '["stringData"]["age.agekey"]' bootstrap/sops-age.sops.yaml` ([SOPS age docs](https://getsops.io/docs/usage/identities/age/)).

## One GPG key on two YubiKeys

The key is generated on the workstation, backed up offline, then moved to each card with `keytocard`. Yubico's guide makes the backup **before** `keytocard` ("Make sure to store the backup offline in a secure place"). After `keytocard`, the keyring keeps "only a pointer indicating that it's stored on a smart card" ([Yubico: importing keys](https://developers.yubico.com/PGP/Importing_keys.html)). For the second card, restore the backup and run `keytocard` again.

**Switching cards.** GnuPG's key stubs point at the card it last saw. After swapping YubiKeys, refresh them:

```bash
gpg-connect-agent "scd serialno" "learn --force" /bye
```

What each part does:

- `SCD` is gpg-agent's "general quote command to redirect everything to the SCdaemon".
- `SERIALNO` "should be used to check for the presence of a card" and is required after a card change ([SERIALNO](https://www.gnupg.org/documentation/manuals/gnupg/Scdaemon-SERIALNO.html)).
- `LEARN --force` means "private key storage will be updated by the result", so the stubs are rewritten for the inserted card.

`--force` and `SCD` are documented in gpg-agent's command help in the [GnuPG source](https://github.com/gpg/gnupg/blob/master/agent/command.c). The HTML manual only lists `LEARN [--send]` ([LEARN](https://www.gnupg.org/documentation/manuals/gnupg/Agent-LEARN.html)).

## `.sops.yaml`

The file in the repo. `CFACE1C58F406FD74713AB0BF1F680022C252805` is the YubiKey GPG key's fingerprint:

```yaml
---
creation_rules:
  # 1. Flux's age private key: GPG (YubiKey) only, never the age key itself
  - path_regex: bootstrap/sops-age\.sops\.yaml$
    encrypted_regex: ^(data|stringData)$
    mac_only_encrypted: true
    pgp: CFACE1C58F406FD74713AB0BF1F680022C252805

  # 2. Workstation-only files: Talos secrets bundle, Terraform secrets + state (whole file)
  - path_regex: (talos|infrastructure)/.*\.sops\.(ya?ml|json)$
    mac_only_encrypted: true
    pgp: CFACE1C58F406FD74713AB0BF1F680022C252805
    age: age1gt9a67gwv8jt30g4ul0rglfq38h0lreul89640jddz9xl0y9qpjs4tcggj

  # 3. Kubernetes Secrets: GPG for me, age for Flux
  - path_regex: (bootstrap|kubernetes)/.*\.sops\.ya?ml$
    encrypted_regex: ^(data|stringData)$
    mac_only_encrypted: true
    pgp: CFACE1C58F406FD74713AB0BF1F680022C252805
    age: age1gt9a67gwv8jt30g4ul0rglfq38h0lreul89640jddz9xl0y9qpjs4tcggj
stores:
  yaml:
    indent: 2
```

How the rules work:

- **Rule order matters.** "Creation rules are evaluated sequentially, the first match wins" ([SOPS config file docs](https://getsops.io/docs/usage/identities/config-file/)). Rule 1 must come before rule 3, which would otherwise also match `bootstrap/sops-age.sops.yaml` and make the age key a recipient of itself.
- **Only `*.sops.*` files match.** The old catch-all `\.ya?ml$` also matched plain manifests. The structure follows [cluster-template's `.sops.yaml`](https://github.com/onedr0p/cluster-template/blob/main/template/config/.sops.yaml.j2): a whole-file rule for `talos/`, and `encrypted_regex` for `bootstrap|kubernetes`. The PGP recipient, rule 1 and the `infrastructure/` (Terraform) path are my additions. cluster-template encrypts its `bootstrap/sops-age.sops.yaml` to the age key itself ([source](https://github.com/onedr0p/cluster-template/blob/main/template/config/bootstrap/sops-age.sops.yaml.j2)), so you need the age key to bootstrap. Rule 1 means you need the YubiKey instead.
- **topf writes `talos/secrets.sops.yaml` through rule 2.** The bundle is "SOPS-encrypted on write if a corresponding SOPS config is found" ([topf secrets](https://github.com/postfinance/topf/blob/main/docs/commands/secrets.md)).
- **Rule 2 includes the age key on purpose.** Flux never reads these files, but the offline age backup gives a second way back to the Talos CA and the Terraform state if both YubiKeys *and* the GPG backup are lost. The cost: if the in-cluster age key leaked, it could decrypt the Talos CA too. I accept that, since the same key already decrypts every app secret.
- **The age key is new.** For the Flux bootstrap ([#178](https://github.com/lorenzorapetti/homelab/issues/178)) I generated a fresh age key instead of reusing the k3s one (`age1dkx5…zpqxuq`). Its backup is the 1Password item "homelab: Flux SOPS age key". See [The age key for Flux](#the-age-key-for-flux).

## Re-encrypting existing files

The k3s-era secrets were moved with the old manifests to `kubernetes_old/`. They are unused and stay encrypted to the **old** age key only. No rule in `.sops.yaml` matches that path any more, so they are never re-encrypted. Moving one of them to the new cluster needs the old key (or the value from wherever it originally came from).

After changing recipients, run `updatekeys` on every encrypted file. It adds or removes master keys "without rotating the data key", and `-y` skips the confirmation prompt ([SOPS key management](https://getsops.io/docs/usage/key-management/)):

```bash
find talos infrastructure bootstrap kubernetes -name '*.sops.*' -print0 | xargs -0 -n1 sops updatekeys -y
```

`updatekeys` has to decrypt the data key first. For files that are still encrypted to age only, the first run needs the age key locally (e.g. `SOPS_AGE_KEY_FILE` pointing at the 1Password export). After a recipient is *removed*, also run `sops rotate --in-place` on each file. SOPS documents the order as first `updatekeys`, then `rotate` ([SOPS key management](https://getsops.io/docs/usage/key-management/)).

The age key rotation for the Flux bootstrap (2026-11-18) did the `updatekeys` part: rules 2 and 3 got the new recipient, and `talos/secrets.sops.yaml`, `infrastructure/secrets.sops.yaml` and `infrastructure/terraform.tfstate.sops.json` were re-keyed to it, decrypting through the YubiKey. The data keys weren't rotated. That only matters if the old age key leaks, and then Git history exposes the old ciphertexts anyway.

## The age key for Flux

A new key, generated with `age-keygen` ([Flux SOPS guide](https://fluxcd.io/flux/guides/mozilla-sops/)) and stored as the `Secret` Flux will use. The file name comes from [cluster-template's `bootstrap/sops-age.sops.yaml`](https://github.com/onedr0p/cluster-template/blob/main/template/config/bootstrap/sops-age.sops.yaml.j2). The private key only ever lived in a tmpfs directory, and the Secret was piped straight into `sops`, so no plaintext copy reached the repo:

```bash
dir=$(mktemp -d -p "$XDG_RUNTIME_DIR")          # tmpfs
age-keygen -o "$dir/age.agekey"                 # prints the public key
# Save the AGE-SECRET-KEY-1… line in 1Password ("homelab: Flux SOPS age key") before going on.
{
  printf -- '---\napiVersion: v1\nkind: Secret\nmetadata:\n  name: sops-age\n  namespace: flux-system\nstringData:\n  age.agekey: |\n'
  grep '^AGE-SECRET-KEY-1' "$dir/age.agekey" | while IFS= read -r l; do printf '    %s\n' "$l"; done
} | sops encrypt --filename-override bootstrap/sops-age.sops.yaml /dev/stdin > bootstrap/sops-age.sops.yaml   # rule 1: GPG only
shred -u "$dir/age.agekey"; rmdir "$dir"
```

Then the new public key replaced the old one in rules 2 and 3 of `.sops.yaml`, and the existing files were re-keyed (see [Re-encrypting existing files](#re-encrypting-existing-files)). `--filename-override` makes sops pick the creation rule for that path while reading stdin.

"The key name must end with `.agekey` to be detected as an age key" ([Flux SOPS guide](https://fluxcd.io/flux/guides/mozilla-sops/)).

**Getting it into the cluster.** During [bootstrap](/kubernetes/getting-started/bootstrap#1-namespace-and-bootstrap-secrets) (`just bootstrap::secrets`), before the helmfile installs Flux:

```bash
kubectl create namespace flux-system --dry-run=client -o yaml | kubectl apply --server-side -f -
sops decrypt bootstrap/sops-age.sops.yaml | kubectl apply --server-side -f -   # touch the YubiKey
```

The decrypted key goes straight from `sops` into `kubectl` and never touches the disk.

## How Flux decrypts

In the k3s repo, every child Kustomization had `decryption.secretRef: sops-age`, so `kubernetes/components/common/sops` copied the key into **every** namespace.

The new setup uses kustomize-controller's **controller-level** key. The `--sops-age-secret` flag points the controller at a Secret holding age keys, which must live in the controller's namespace (`flux-system`). A Kustomization's own `.spec.decryption.secretRef` still takes precedence ([Kustomization API: decryption](https://fluxcd.io/flux/components/kustomize/kustomizations/)). The flag is set through a FluxInstance kustomize patch, and the same instance patches set `decryption.provider: sops` on the `flux-system` Kustomization and on every child ([Flux](/kubernetes/flux/intro#the-fluxinstance)). As a result:

- The private key exists once, in `flux-system`.
- `kubernetes/components/common/sops` goes away. The new `kubernetes/components/sops` holds only a `cluster-secrets` Secret for `postBuild` substitution, such as `SECRET_DOMAIN` ([cluster-template](https://github.com/onedr0p/cluster-template/blob/main/template/config/kubernetes/components/sops/cluster-secrets.sops.yaml.j2)).

## Recovery

Keep both of these **offline**, e.g. on paper or an encrypted USB stick in a drawer, plus 1Password:

- **The GPG key backup**, exported before `keytocard` as Yubico recommends ([importing keys](https://developers.yubico.com/PGP/Importing_keys.html)). It replaces a lost or broken YubiKey: restore it and `keytocard` onto a new card.
- **The age private key** (in 1Password as "homelab: Flux SOPS age key"). It decrypts everything except `bootstrap/sops-age.sops.yaml`, and that file only contains the age key anyway.

With either backup and the repo, the whole cluster can be rebuilt: Terraform, Talos and Flux.
