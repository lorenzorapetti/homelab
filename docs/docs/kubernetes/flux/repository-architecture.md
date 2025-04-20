---
sidebar_position: 2
---

# Repository Architecture

The repository has a number of folders:

```
kubernetes/
├─ apps/
├─ cluster/
│  ├─ infrastructure.yaml
│  ├─ flux-system/
│  │  ├─ gotk-components.yaml
│  │  ├─ gotk-sync.yaml
│  │  ├─ kustomization.yaml
├─ infrastructure/
│  ├─ cert-manager/
│  ├─ sealed-secrets/
```

When fluxed is bootstrapped with `--path=kubernetes/cluster`, the controller checks this directory and tries to reconcile the cluster. It looks at `infrastructure.yaml` and sees that there are `Kustomization` objects:

- `sealed-secrets` is the first one to be reconciled because every other object depends on it.
- `cert-manager` comes after, because it needs the Cloudflare token Sealed Secret to work with the DNS challenge.
- `apps` is the last one to be reconciled. It contains all the applications that are deployed in the cluster. It has a dependency on both `cert-manager` and `sealed-secrets`, so it is the last one to be reconciled.

This structure ensures that objects that are required to deploy apps (CRDs like `SealedSecret`, `Certificate`, etc.) are always deployed before the apps themselves.
