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
│     └─ default.yaml, templates/ # read chart + values from kubernetes/apps/**
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
  - ./longhorn-system
  - ./cert-manager
```

This is the built file as of [#183](https://github.com/lorenzorapetti/homelab/issues/183). Without this file, Flux would generate one "for all the Kubernetes manifests in the directory tree" ([Kustomization API](https://fluxcd.io/flux/components/kustomize/kustomizations/)). cluster-template relies on that. I keep the explicit list because the directory would otherwise be empty at first, and because it makes "add a namespace" a visible one-line diff.

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

### `flux-system`: prune disabled on everything

The namespace annotation alone isn't enough for `flux-system`. The `deletionPolicy: WaitForTermination` that the FluxInstance injects into every `ks.yaml` would let a deleted `flux-system/` directory cascade down to uninstalling Flux. So `kubernetes/apps/flux-system/kustomization.yaml` puts the annotation on everything it creates:

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: flux-system
commonAnnotations:
  kustomize.toolkit.fluxcd.io/prune: disabled
components:
  - ../../components/sops
resources:
  - ./namespace.yaml
  - ./flux-operator/ks.yaml
  - ./flux-instance/ks.yaml
```

Both `ks.yaml` files add it to their HelmRelease and OCIRepository through `spec.commonMetadata.annotations`. The chain, the source code it relies on, and the prune test are on the [Flux page](/kubernetes/flux/intro#flux-must-never-uninstall-itself). Other namespaces don't need this: deleting an app is supposed to uninstall it.

### `kube-system`: no `namespace.yaml`

`kube-system` is created by Kubernetes, so `kubernetes/apps/kube-system/kustomization.yaml` has `namespace: kube-system` and the `sops` component, but no `namespace.yaml`. The `namespace:` field only sets `metadata.namespace` on the objects in the build. It doesn't create a Namespace object, so Flux never owns or prunes `kube-system`. After the Cilium app was reconciled, `kubectl get namespace kube-system --show-labels` still showed only `kubernetes.io/metadata.name` and `name`, with no `kustomize.toolkit.fluxcd.io/*` labels. Use the same approach for any other namespace that Kubernetes or a bootstrap step creates.

## `cluster-secrets`

`kubernetes/components/sops/` is a Kustomize `Component` (`kustomize.config.k8s.io/v1alpha1`) with one resource, `secret.sops.yaml`:

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: cluster-secrets
stringData:
  SECRET_DOMAIN: "<the base domain>"
```

- **Naming.** One key per variable, named `SECRET_<NAME>` and used in manifests as `${SECRET_<NAME>}`, as in cluster-template. The prefix makes substituted values easy to grep for, and it can't collide with the `$`-variables that charts use in their own values.
- **Only what an app uses.** It starts with `SECRET_DOMAIN`, for the wildcard certificate and the `HTTPRoute` hostnames. Add a variable in the same commit as the first app that references it.
- **Encryption.** The filename matches SOPS rule 3, so the file is encrypted to the YubiKey GPG key and Flux's age key ([SOPS](/kubernetes/sops)). Encrypting needs only the public keys. Editing it later with `sops` needs the YubiKey.
- **One copy per namespace.** Every namespace's `kustomization.yaml` includes the component, so the `flux-system` Kustomization creates `cluster-secrets` in each namespace. `postBuild.substituteFrom` can only read a Secret in the Kustomization's own namespace. In `kube-system` it decrypted to the value I entered.

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

Both files are the k3s repo's `ks.yaml` with `patches: []` and `postBuild` added. The k3s `cert-manager/ks.yaml` also health-checked the `cert-manager` `Deployment`. That check is dropped: helm-controller waits for the release's resources before it marks the `HelmRelease` Ready, so the `HelmRelease` check already covers it. Field semantics, per the [Kustomization API](https://fluxcd.io/flux/components/kustomize/kustomizations/):

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

**Kubernetes 1.37.** v1.21.3 was the latest patch on 2026-11-19. cert-manager lists 1.21 as supported and tested on Kubernetes 1.33 → 1.36 ([supported releases](https://cert-manager.io/docs/releases/)), and this cluster runs 1.37.2. No newer release exists yet: 1.22 is listed as "~Nov 2026". The chart's `kubeVersion` is `>= 1.22.0-0`, so it installs, and cert-manager only uses stable APIs. Move to 1.22 once it is released and lists 1.37.

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

`secret.sops.yaml` is the Secret `cloudflare-token` with the key `apiToken`, encrypted by SOPS rule 3. It is created by piping the YAML into `sops encrypt --filename-override <path> /dev/stdin`, so the token never lands on disk in plaintext ([SOPS](/kubernetes/sops)).

### `cluster-issuer/app/cluster-issuer.yaml`

Two `ClusterIssuer`s share the Cloudflare DNS-01 solver:

| Name | ACME server | Account key Secret |
| --- | --- | --- |
| `cloudflare-cluster-issuer` | Let's Encrypt production | `cloudflare-cluster-issuer-account-key` |
| `cloudflare-cluster-issuer-staging` | Let's Encrypt staging | `cloudflare-cluster-issuer-staging-account-key` |

The production names are carried over from the k3s repo. The staging issuer is for testing. Its certificates aren't browser-trusted, but a test doesn't count against production rate limits. Both reference `cloudflare-token` in `cert-manager`, which is cert-manager's "cluster resource namespace" for `ClusterIssuer` secrets. A `ClusterIssuer` is cluster-scoped, so the namespace that `targetNamespace` sets on it is ignored.

### Routing an app

With Cilium's Gateway, an app's ingress is an `HTTPRoute` in its `app/` directory, attached to the shared Gateway ([Bootstrap: the shared Gateway](/kubernetes/getting-started/bootstrap#the-shared-gateway)):

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

This replaces the Traefik `IngressRoute`s and per-app `Certificate`s from the k3s repo. TLS terminates at the Gateway with one wildcard certificate, as in Jonas's setup ([post 6](https://jonashietala.se/blog/2026/08/06/domains_certificates_and_dns)). `${SECRET_DOMAIN}` is substituted by Flux from `cluster-secrets`, so the app's `ks.yaml` needs `postBuild.substituteFrom: cluster-secrets`. The backend port is illustrative.

- **Always `sectionName: https`.** The `http` listener only accepts routes from `kube-system`, where one `HTTPRoute` sends every plain-HTTP request to HTTPS with a `301`. A route from another namespace that targets `http` is rejected (`NotAllowedByListeners`), so no app serves plaintext.
- **One label under the domain.** The certificate covers the apex and `*.<domain>`, so `glance.<domain>` works but `a.b.<domain>` would need a new SAN.
- **No per-app certificate, no `ReferenceGrant`.** The Gateway reads its own Secret in `kube-system`, and routes from any namespace may attach to `https` (`from: All`).
- **Depend on `gateway`** in the app's `ks.yaml` (`dependsOn: [{name: gateway, namespace: kube-system}]`), so the route is applied only once the Gateway is programmed.

### Charts without an OCI registry

Not every chart is published to an OCI registry. Longhorn's chart, for example, is only served from `https://charts.longhorn.io` (verified 2026-11-19; see `kubernetes/apps/longhorn-system/longhorn/app/helmrepository.yaml`). For those, keep a `HelmRepository` and use `chart.spec` in the HelmRelease, as Longhorn does. I haven't verified which of my charts publish OCI; check each one as you migrate it. The bootstrap helmfile templates only read `ocirepository.yaml`, so the bootstrap charts (Cilium, Flux Operator, FluxInstance) must use OCI. All three do.
