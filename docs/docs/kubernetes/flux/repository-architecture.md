---
sidebar_position: 2
---

# Repository Architecture

The repository follows the "home-ops" layout from [onedr0p/cluster-template](https://github.com/onedr0p/cluster-template): Terraform, Talos, the bootstrap and the Kubernetes manifests sit side by side. **Every app gets its own Flux `Kustomization`**, with explicit `dependsOn` and health checks.

```
.
├─ devenv.nix, devenv.yaml        # tools: terraform, sops, gpg, age, just, talosctl, topf
├─ justfile                       # mod tf / talos / bootstrap
├─ .sops.yaml                     # SOPS rules (GPG + age)
├─ renovate.json
├─ infrastructure/                # Terraform: Proxmox VMs (bpg/proxmox)
│  ├─ mod.just
│  ├─ *.tf, variables.auto.tfvars
│  ├─ secrets.sops.yaml           # Proxmox API token
│  └─ terraform.tfstate.sops.json
├─ talos/                         # topf
│  ├─ mod.just
│  ├─ topf.yaml
│  ├─ schematic.yaml
│  ├─ secrets.sops.yaml
│  ├─ all/  control-plane/
├─ bootstrap/                     # one-time install, before Flux exists
│  ├─ mod.just
│  ├─ sops-age.sops.yaml
│  ├─ github-deploy-key.sops.yaml
│  └─ helmfile/
│     ├─ apps.yaml                # cilium → flux-operator → flux-instance
│     ├─ values/                  # skeleton: bootstrap-only values
│     └─ default.yaml, templates/ # later: read chart + values from kubernetes/apps/**
└─ kubernetes/
   ├─ components/
   │  └─ sops/                    # cluster-secrets (postBuild substitution vars)
   └─ apps/                       # ← FluxInstance spec.sync.path
      ├─ kustomization.yaml       # lists namespace directories
      └─ <namespace>/
         ├─ kustomization.yaml    # namespace + components + list of ks.yaml
         ├─ namespace.yaml
         └─ <app>/
            ├─ ks.yaml            # Flux Kustomization: dependsOn, healthChecks
            └─ app/
               ├─ kustomization.yaml
               ├─ helmrelease.yaml
               ├─ ocirepository.yaml
               └─ secret.sops.yaml
```

This tree is the **end state**. After the [bootstrap](/kubernetes/getting-started/bootstrap), `kubernetes/` holds only an empty `kubernetes/apps/kustomization.yaml`. Everything under `kubernetes/apps/<namespace>/` and `kubernetes/components/` is added by hand, one app per commit, following [Migrating from k3s](/kubernetes/migration). The manifests on this page are examples for when you reach that app, not files to create up front.

| Path | What it is |
| --- | --- |
| `justfile`, `*/mod.just` | Task runner modules ([justfile](/kubernetes/getting-started/bootstrap#the-justfile)) |
| `devenv.nix` | Every CLI tool, pinned. Run commands in `devenv shell` |
| `infrastructure/` | Terraform for the Proxmox VMs ([Deploying the infrastructure](/kubernetes/getting-started/deploying-the-infrastructure)). Named after Jonas's repo, as is `kubernetes/` (his `gitops/`) |
| `talos/` | topf config, patches and the SOPS-encrypted secrets bundle ([Install Talos](/kubernetes/getting-started/install-talos)) |
| `bootstrap/` | Everything needed **before** Flux runs: the age key, the Git pull secret, and the helmfile for Cilium and Flux |
| `kubernetes/apps/` | The path the `FluxInstance` syncs directly. There is no `kubernetes/flux/cluster/ks.yaml` |
| `kubernetes/components/` | [Kustomize components](https://kubectl.docs.kubernetes.io/guides/config_management/components/) included by every namespace's `kustomization.yaml` |
| `kubernetes/apps/<ns>/<app>/ks.yaml` | The Flux `Kustomization` for one app: ordering (`dependsOn`) and readiness (`healthChecks`) |
| `kubernetes/apps/<ns>/<app>/app/` | The manifests: `HelmRelease`, its chart source, SOPS secrets, `HTTPRoute`s, PVCs |

Flux's own [repository structure guide](https://fluxcd.io/flux/guides/repository-structure/) orders reconciliation by layer: `apps/`, `infrastructure/` and `clusters/`, because "the separation between apps and infrastructure makes it possible to define the order". Here there is one cluster with no environments, so ordering is per app: each `ks.yaml` declares what it needs.

## No root Kustomization

The k3s repo had `kubernetes/cluster/ks.yaml`, a root Kustomization that patched SOPS decryption into every child. In the new layout:

- **The `FluxInstance` syncs `kubernetes/apps` directly.** It creates a GitRepository + Kustomization named `flux-system` with `path: kubernetes/apps` ([FluxInstance docs](https://fluxoperator.dev/docs/crd/fluxinstance/)).
- **The root's job moves into `FluxInstance.spec.kustomize.patches`.** Those patches target that `flux-system` Kustomization, add `decryption.provider: sops` and `deletionPolicy`, and inject the same settings plus HelmRelease defaults into every child.

This is what cluster-template has done since it [removed `kubernetes/flux/cluster/ks.yaml`](https://github.com/onedr0p/cluster-template/pull/2468) on 2026-10-24. The full patch is on the [Flux page](/kubernetes/flux/intro#the-fluxinstance). The consequence for every app: **each `ks.yaml` must contain `patches: []`**, because the injected patch does a JSON6902 `add` at `/spec/patches/0`.

## The top-level `kubernetes/apps/kustomization.yaml`

In the skeleton it is `resources: []`. Add each namespace directory as it arrives:

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./kube-system
  - ./flux-system
```

Without this file, Flux would generate one "for all the Kubernetes manifests in the directory tree" ([Kustomization API](https://fluxcd.io/flux/components/kustomize/kustomizations/)). cluster-template relies on that. I keep the explicit list because the directory would otherwise be empty at first, and because it makes "add a namespace" a visible one-line diff.

## A namespace

`kubernetes/apps/cert-manager/kustomization.yaml`:

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: cert-manager
components:
  - ../../components/sops
resources:
  - ./namespace.yaml
  - ./cert-manager/ks.yaml
  - ./cluster-issuer/ks.yaml
```

The `namespace:` field puts every `ks.yaml` in the app's namespace, as the current repo already does. The `sops` component adds the `cluster-secrets` Secret, so `postBuild.substituteFrom` can reference it from the same namespace ([cluster-template namespace kustomization](https://github.com/onedr0p/cluster-template/blob/main/template/config/kubernetes/apps/cert-manager/kustomization.yaml.j2)). For `flux-system`, cluster-template marks the namespace with `kustomize.toolkit.fluxcd.io/prune: disabled`, so Flux never prunes its own namespace ([namespace.yaml](https://github.com/onedr0p/cluster-template/blob/main/template/config/kubernetes/apps/flux-system/namespace.yaml.j2)).

## An app: cert-manager

### `cert-manager/ks.yaml`

```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: &app cert-manager
spec:
  commonMetadata:
    labels:
      app.kubernetes.io/name: *app
  interval: 1h
  path: ./kubernetes/apps/cert-manager/cert-manager/app
  patches: []                       # required by the FluxInstance's injected patch
  postBuild:
    substituteFrom:
      - name: cluster-secrets
        kind: Secret
  prune: true
  retryInterval: 2m
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  targetNamespace: cert-manager
  timeout: 5m
  healthChecks:
    - apiVersion: helm.toolkit.fluxcd.io/v2
      kind: HelmRelease
      name: cert-manager
      namespace: cert-manager
```

### `cluster-issuer/ks.yaml`

The `ClusterIssuer` is a separate app because its CRD exists only once the chart is installed:

```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: &app cluster-issuer
spec:
  commonMetadata:
    labels:
      app.kubernetes.io/name: *app
  dependsOn:
    - name: cert-manager
      namespace: cert-manager
  interval: 1h
  path: ./kubernetes/apps/cert-manager/cluster-issuer/app
  patches: []
  prune: true
  retryInterval: 2m
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  targetNamespace: cert-manager
  timeout: 5m
  healthCheckExprs:
    - apiVersion: cert-manager.io/v1
      kind: ClusterIssuer
      current: status.conditions.filter(e, e.type == 'Ready').all(e, e.status == 'True')
      failed: status.conditions.filter(e, e.type == 'Ready').all(e, e.status == 'False')
```

Both files are the current repo's `ks.yaml` with `patches: []` and `postBuild` added. Field semantics, per the [Kustomization API](https://fluxcd.io/flux/components/kustomize/kustomizations/):

- **`dependsOn`** waits until the referenced Kustomization is `Ready`.
- **`healthChecks`** gates readiness on the listed objects. Setting `wait: true` would check everything instead and ignore `healthChecks`.
- **`healthCheckExprs`** defines CEL health for custom resources.
- **`targetNamespace`** doesn't create the namespace.

### `cert-manager/app/ocirepository.yaml`

```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/source.toolkit.fluxcd.io/ocirepository_v1.json
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: cert-manager
spec:
  interval: 15m
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
  ref:
    tag: v1.21.3
  url: oci://quay.io/jetstack/charts/cert-manager
```

`source.toolkit.fluxcd.io/v1` with a required `interval`. `ref.tag`/`semver`/`digest` are supported, with digest taking precedence, and `operation: copy` keeps the chart tarball "as-is" ([OCIRepository API](https://fluxcd.io/flux/components/source/ocirepositories/)). The URL and tag come from [cluster-template](https://github.com/onedr0p/cluster-template/blob/main/template/config/kubernetes/apps/cert-manager/cert-manager/app/ocirepository.yaml.j2). The k3s repo pinned v1.19.1 from `https://charts.jetstack.io`.

### `cert-manager/app/helmrelease.yaml`

```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/helm.toolkit.fluxcd.io/helmrelease_v2.json
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: cert-manager
spec:
  interval: 1h
  chartRef:
    kind: OCIRepository
    name: cert-manager
  values:
    crds:
      enabled: true
    extraArgs:
      - --dns01-recursive-nameservers-only
      - --dns01-recursive-nameservers=1.1.1.1:53,1.0.0.1:53
```

"One of `.spec.chart` or `.spec.chartRef` must be set, but not both", and `chartRef` accepts `OCIRepository` ([HelmRelease API](https://fluxcd.io/flux/components/helm/helmreleases/)). The CRD install/upgrade policies come from the injected defaults. The values are carried over from the current repo.

### `cert-manager/app/kustomization.yaml`

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./helmrelease.yaml
  - ./ocirepository.yaml
  - ./secret.sops.yaml     # Cloudflare API token (was cloudflare-secret.yaml)
```

### Routing an app

With Cilium's Gateway, an app's ingress is an `HTTPRoute` in its `app/` directory, attached to the shared Gateway ([Bootstrap: Cilium networking](/kubernetes/getting-started/bootstrap#cilium-networking)):

```yaml
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: glance
spec:
  parentRefs:
    - name: main
      namespace: kube-system
      sectionName: https
  hostnames: ["glance.${SECRET_DOMAIN}"]
  rules:
    - backendRefs:
        - name: glance
          port: 8080
```

This replaces the Traefik `IngressRoute`s and per-app `Certificate`s from the k3s repo. TLS terminates at the Gateway with one wildcard certificate, as in Jonas's setup ([post 6](https://jonashietala.se/blog/2026/08/06/domains_certificates_and_dns)). `${SECRET_DOMAIN}` is substituted by Flux from `cluster-secrets`. The backend port is illustrative.

### Charts without an OCI registry

Not every chart is published to an OCI registry. Longhorn's chart, for example, is served from `https://charts.longhorn.io` ([Talos Longhorn guide](https://docs.siderolabs.com/kubernetes-guides/csi/longhorn.md)). For those, keep a `HelmRepository` and use `chart.spec` in the HelmRelease, as the current repo does. I haven't verified which of my charts publish OCI; check each one as you migrate it. The bootstrap helmfile templates only read `ocirepository.yaml`, so the bootstrap charts (Cilium, Flux Operator, FluxInstance) must use OCI. All three do.
