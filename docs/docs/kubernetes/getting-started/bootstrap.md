---
sidebar_position: 3
---

# Bootstrap the cluster

Once [Talos is installed](/kubernetes/getting-started/install-talos), the cluster has an API server but no CNI and no Flux. This page covers the one-time sequence that hands control to Git. The result is a **bare skeleton**:

- Talos, with Cilium as CNI and kube-proxy replacement
- the Flux Operator and a `FluxInstance` that syncs `kubernetes/apps/` directly
- the `flux-system/sops-age` Secret and the Git pull secret
- an **empty** `kubernetes/apps/`

No apps yet. They are added **one at a time, one commit/PR each**, following [Migrating from k3s](/kubernetes/migration).

That was the first bootstrap. **Rebuilding the cluster** later is the same `just full`, but `kubernetes/apps/` is no longer empty. The helmfile installs Cilium and Flux from their Flux manifests ([one source of truth](#one-source-of-truth-for-values)). Flux then takes over those three releases ([what the takeover does](#what-the-takeover-does-flux-2026-11-19)) and installs every other app in `kubernetes/apps/`.

```
terraform apply          → 3 VMs in maintenance mode (10.0.11.1–3)
topf apply --auto-bootstrap → Talos + etcd, no CNI
   │
   ├─ 1. flux-system namespace + bootstrap secrets (sops-age, Git pull secret)
   ├─ 2. Gateway API CRDs
   ├─ 3. helmfile: cilium ─▶ flux-operator ─▶ flux-instance
   ▼
FluxInstance → GitRepository + Kustomization "flux-system" → kubernetes/apps/ (empty)
```

It is the same shape as Jonas's `just bootstrap::full`: cluster, Cilium, secrets key, GitOps controller ([post 3](https://jonashietala.se/blog/2026/05/28/just_command_runner_documentation), [post 5](https://jonashietala.se/blog/2026/07/23/gitops_with_argocd)). The difference is that there is no `root.yaml` to apply by hand: the `FluxInstance` creates the root sync itself. The whole sequence is wrapped in a [justfile](#the-justfile).

## What the repo needs before bootstrapping

| File | Purpose |
| --- | --- |
| `bootstrap/sops-age.sops.yaml` | Flux's age key, encrypted to the YubiKey only ([SOPS](/kubernetes/sops#the-age-key-for-flux)) |
| `bootstrap/github-deploy-key.sops.yaml` | SSH pull secret `flux-system` (`identity`, `known_hosts`) |
| `bootstrap/helmfile/apps.yaml`, `default.yaml`, `templates/` | The releases for Cilium, flux-operator, flux-instance. Chart, version and values are read from the Flux manifests below ([one source of truth](#one-source-of-truth-for-values)) |
| `kubernetes/apps/kube-system/cilium/app/`, `kubernetes/apps/flux-system/{flux-operator,flux-instance}/app/` | Each release's `ocirepository.yaml` and `helmrelease.yaml`, which the helmfile reads |
| `kubernetes/apps/kube-system/gateway-api-crds/ks.yaml` | The Gateway API tag, which `just bootstrap::crds` reads ([step 2](#2-gateway-api-crds)) |
| `kubernetes/apps/kustomization.yaml` | The list of namespace directories Flux syncs. The very first bootstrap used an empty one (`resources: []`), so the path existed in Git |

There is no `kubernetes/flux/cluster/ks.yaml`. The FluxInstance syncs `kubernetes/apps` directly ([Repository Architecture](/kubernetes/flux/repository-architecture)). Git doesn't track empty directories, so `kubernetes/apps/` needs that one file. kustomize-controller treats `resources: []` as "nothing to apply": on the first reconcile `flux-system` reported Ready with "Applied revision: refs/heads/main@sha1:6e0d1748" (2026-11-18).

## 0. Wait for the API server

The nodes stay `NotReady` until the CNI exists, so wait until the nodes have *registered*, not until they are Ready. That's what cluster-template's `apps-ready` task ([source](https://github.com/onedr0p/cluster-template/blob/main/template/config/bootstrap/mise.toml)) and Jonas's `wait_for_api` recipe ([post 3](https://jonashietala.se/blog/2026/05/28/just_command_runner_documentation)) both do.

## 1. Namespace and bootstrap secrets

```bash
kubectl create namespace flux-system --dry-run=client -o yaml | kubectl apply --server-side -f -
sops decrypt bootstrap/sops-age.sops.yaml          | kubectl apply --server-side -f -   # YubiKey: PIN + touch
sops decrypt bootstrap/github-deploy-key.sops.yaml | kubectl apply --server-side -f -
```

This mirrors cluster-template's `apps-secrets` task, which runs `sops decrypt` and pipes the result to `kubectl apply --server-side` ([source](https://github.com/onedr0p/cluster-template/blob/main/template/config/bootstrap/mise.toml)). Two details are mine:

- **`sops-age` is encrypted to the YubiKey only.** The YubiKey is all you need to bootstrap.
- **The pull secret is named `flux-system`**, the name `flux bootstrap` used. The repo had no deploy key left, so it holds a new ed25519 key, added to GitHub as a **read-only** deploy key titled "flux (homelab cluster, read-only)". `known_hosts` comes from `gh api meta` (GitHub's published host keys over TLS) rather than an `ssh-keyscan`. The private half exists only in this encrypted file: if it's lost, generate a new key and replace the deploy key. It uses the `identity`/`known_hosts` keys of [cluster-template's deploy key](https://github.com/onedr0p/cluster-template/blob/main/template/config/bootstrap/deploy-key.sops.yaml.j2).

## 2. Gateway API CRDs

Cilium's Gateway API controller needs the Gateway API CRDs **before** Cilium starts. Cilium 1.20 documents Gateway API **v1.6.3** and requires `TLSRoute`. Either channel works, but experimental features need the experimental channel ([Cilium Gateway API docs](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api/)). The `ExternalAuth` HTTPRoute filter (GEP-1494, status *Experimental*, [GEP](https://gateway-api.sigs.k8s.io/geps/gep-1494/)) is the cleanest way to put Authentik in front of apps (see [Authentik forward auth](/kubernetes/migration#authentik-forward-auth-with-cilium-gateway)), so install the **experimental** channel:

```bash
kubectl apply --server-side \
  -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.3/experimental-install.yaml
```

Both `standard-install.yaml` and `experimental-install.yaml` are assets of the [v1.6.3 release](https://github.com/kubernetes-sigs/gateway-api/releases/tag/v1.6.3). Jonas applies the CRDs first for the same reason ([post 2](https://jonashietala.se/blog/2026/05/22/talos_linux_on_proxmox_with_terraform)). Besides the CRDs, the experimental bundle also installs a `ValidatingAdmissionPolicy` and binding named `safe-upgrades.gateway.networking.k8s.io`, and three `gateway.networking.x-k8s.io` CRDs (`XBackend`, `XBackendTrafficPolicy`, `XMesh`).

`just bootstrap::crds` runs this command, with the tag read from the Flux manifest below. Once Flux runs, it owns the CRDs (step 3 of the [migration](/kubernetes/migration)).

### The CRDs as a Flux app

`kubernetes/apps/kube-system/gateway-api-crds/ks.yaml` holds two objects, a `GitRepository` and the Kustomization that applies it:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: gateway-api-crds
spec:
  interval: 1h
  url: https://github.com/kubernetes-sigs/gateway-api
  ref:
    tag: v1.6.3
  ignore: |
    /*
    !/config/crd/experimental/
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: &app gateway-api-crds
spec:
  commonMetadata:
    labels:
      app.kubernetes.io/name: *app
    annotations:
      kustomize.toolkit.fluxcd.io/prune: disabled
  interval: 1h
  path: ./config/crd/experimental
  patches: []
  prune: true
  retryInterval: 2m
  sourceRef:
    kind: GitRepository
    name: gateway-api-crds
  timeout: 5m
  wait: true
```

- **No `app/` directory.** The `GitRepository` has to exist before the Kustomization can read from it, so `flux-system` applies both from `ks.yaml`. In an `app/` directory, the Kustomization would have to apply its own source. `ignore` keeps the artifact down to the one directory.
- **The same objects as `experimental-install.yaml`.** `config/crd/experimental` has its own `kustomization.yaml` ([tree](https://github.com/kubernetes-sigs/gateway-api/tree/v1.6.3/config/crd/experimental)). Its `kubectl kustomize` build has the same 15 objects as the release asset, with identical content (I compared them as sorted YAML, 2026-11-19). So Flux also manages the `safe-upgrades` policy and the three `x-k8s.io` CRDs.
- **No `targetNamespace`.** Every object is cluster-scoped. The `GitRepository` and the Kustomization end up in `kube-system` from the namespace's `kustomization.yaml`.
- **`prune: disabled` on every object, not `prune: false`.** Deleting the CRDs deletes every `Gateway` and `HTTPRoute`. `prune: false` doesn't prevent that here: the FluxInstance injects `deletionPolicy: WaitForTermination` into every child Kustomization ([the FluxInstance](/kubernetes/flux/intro#the-fluxinstance)), and that policy deletes the managed objects whatever `prune` says. `MirrorPrune`, the default, is the only policy that follows `prune` ([Kustomization API](https://fluxcd.io/flux/components/kustomize/kustomizations/#deletion-policy)). The `kustomize.toolkit.fluxcd.io/prune: disabled` annotation is skipped by both garbage collection and deletion, the same way `flux-instance` protects itself. `prune: true` stays for consistency with the other apps, and it has nothing to delete. To test the guard, delete the Kustomization **without suspending it first**: a suspended Kustomization never deletes anything when it is removed (`finalizerShouldDeleteResources` returns false on `spec.suspend`), so that test passes even without the annotation.
- **`wait: true`** makes the Kustomization Ready only once the CRDs are `Established`. The `gateway` app will `dependsOn` it.
- **Renovate** reads `ref.tag` on a GitHub `GitRepository` with its `flux` manager, and `just bootstrap::crds` reads the same tag with `yq`. One bump covers both.

### Taking over the kubectl-applied CRDs

The CRDs were applied by `kubectl apply --server-side`, so their field manager is `kubectl` (operation `Apply`). Before pushing, I applied the build with `kubectl apply --server-side --dry-run=server --field-manager=kustomize-controller` and no `--force-conflicts` (2026-11-19):

- the 13 CRDs applied cleanly;
- the `safe-upgrades` `ValidatingAdmissionPolicy` and binding conflicted with `kubectl` on `.spec.matchConstraints` and `.spec.matchResources`.

kustomize-controller handles both. It applies with forced ownership (`client.ForceOwnership` in [fluxcd/pkg `ssa`](https://github.com/fluxcd/pkg/blob/main/ssa/manager_apply.go)), and on its first apply it removes the `kubectl` `Apply` and `Update` managers "to undo changes made with 'kubectl apply --server-side --force-conflicts'" ([kustomization_controller.go](https://github.com/fluxcd/kustomize-controller/blob/main/internal/controller/kustomization_controller.go)). After the takeover, kustomize-controller is the only manager of those fields.

The flip side: on the running cluster, `just bootstrap::crds` now conflicts with kustomize-controller on the policy. It is for fresh clusters only. To upgrade, bump the tag ([Upgrades](/kubernetes/upgrades#gateway-api-crds)).

## 3. helmfile: Cilium, Flux Operator, FluxInstance

`bootstrap/helmfile/apps.yaml`:

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/helmfile
bases:
  - ./default.yaml
---
helmDefaults:
  cleanupOnFail: true
  forceConflicts: true
  wait: true
  waitForJobs: true

releases:
  - name: cilium
    namespace: kube-system
    inherit: [{template: default}]

  - name: flux-operator
    namespace: flux-system
    inherit: [{template: default}]
    needs: ["kube-system/cilium"]

  - name: flux-instance
    namespace: flux-system
    inherit: [{template: default}]
    needs: ["flux-system/flux-operator"]
```

This is the built file, installed by `just bootstrap::helmfile`. `cilium` came first ([#177](https://github.com/lorenzorapetti/homelab/issues/177)), then `flux-operator` and `flux-instance` ([#178](https://github.com/lorenzorapetti/homelab/issues/178)), each with its chart, version and values written out here and in a `values/` directory. Since [#180](https://github.com/lorenzorapetti/homelab/issues/180) the releases only name the template, and everything else comes from the Flux manifests ([below](#one-source-of-truth-for-values)).

The order, `needs` chain and `helmDefaults` come from [cluster-template's `apps.yaml`](https://github.com/onedr0p/cluster-template/blob/main/template/config/bootstrap/helmfile/apps.yaml.j2), minus `coredns`, `spegel` and `cert-manager`. CoreDNS stays Talos-managed, and cert-manager arrives later as an app. The chart URLs are the ones cluster-template's `ocirepository.yaml` files use. The Flux Operator docs give the same `oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator` source ([operator install](https://github.com/controlplaneio-fluxcd/flux-operator/blob/main/docs/guides/operator/operator-install.md)). The `flux-instance` values are on the [Flux page](/kubernetes/flux/intro#the-fluxinstance).

### One source of truth for values

The helmfile uses cluster-template's trick of **reading chart, version and values from the Flux manifests**, so Git holds one copy of each and a fresh `just bootstrap::apps` installs exactly what Flux then takes over:

```yaml
# bootstrap/helmfile/default.yaml
templates:
  default:
    chart: '{{ (fromYaml (tpl (readFile "./templates/release.yaml.gotmpl") .)).chart }}'
    version: '{{ (fromYaml (tpl (readFile "./templates/release.yaml.gotmpl") .)).version }}'
    values:
      - ./templates/values.yaml.gotmpl
```

```
{{/* bootstrap/helmfile/templates/release.yaml.gotmpl */}}
{{- $oci := fromYaml (readFile (printf "../../kubernetes/apps/%s/%s/app/ocirepository.yaml" .Release.Namespace .Release.Name)) -}}
chart: {{ $oci.spec.url }}
version: {{ $oci.spec.ref.tag }}
```

```
{{/* bootstrap/helmfile/templates/values.yaml.gotmpl */}}
{{ (fromYaml (readFile (printf "../../../kubernetes/apps/%s/%s/app/helmrelease.yaml" .Release.Namespace .Release.Name))).spec.values | toYaml }}
```

These are from cluster-template ([default.yaml](https://github.com/onedr0p/cluster-template/blob/main/template/config/bootstrap/helmfile/default.yaml.j2), [release.yaml.gotmpl](https://github.com/onedr0p/cluster-template/blob/main/template/config/bootstrap/helmfile/templates/release.yaml.gotmpl.j2), [values.yaml.gotmpl](https://github.com/onedr0p/cluster-template/blob/main/template/config/bootstrap/helmfile/templates/values.yaml.gotmpl.j2)). `apps.yaml` loads `default.yaml` through `bases:`, and each release uses `inherit: [{template: default}]`. This removes the duplicated Cilium values that Jonas couldn't avoid with ArgoCD ([post 5](https://jonashietala.se/blog/2026/07/23/gitops_with_argocd)). A release without values, like `flux-operator`, has `values: {}` in its HelmRelease so the template has something to read.

- **The two paths differ by one `../`, and both are right.** The release template is read with `readFile` from `default.yaml`, so its path is relative to `bootstrap/helmfile/`. The values template is a values file, and its `readFile` resolves from `bootstrap/helmfile/templates/`. I checked both with `helmfile build` (chart `oci://…`, version `1.20.5`/`0.62.1`) and `helmfile write-values`, whose output matched the old `values/cilium.yaml` and `values/flux-instance.yaml` key for key. The only difference was the key order, because `toYaml` sorts keys.
- **`values/` is gone.** Change a chart version or a value in `kubernetes/apps/…/app/` and nowhere else.

### Cilium networking

The Cilium values, `spec.values` of `kubernetes/apps/kube-system/cilium/app/helmrelease.yaml` (before [#180](https://github.com/lorenzorapetti/homelab/issues/180), `bootstrap/helmfile/values/cilium.yaml`):

```yaml
# The Cilium version this cluster was first installed with. Never bump it.
upgradeCompatibility: "1.20"

# Talos requirements (Talos Cilium guide)
ipam:
  mode: kubernetes
kubeProxyReplacement: true
k8sServiceHost: localhost       # KubePrism
k8sServicePort: 7445
cgroup:
  autoMount:
    enabled: false
  hostRoot: /sys/fs/cgroup
securityContext:
  capabilities:
    ciliumAgent: [CHOWN, KILL, NET_ADMIN, NET_RAW, IPC_LOCK, SYS_ADMIN, SYS_RESOURCE, DAC_OVERRIDE, FOWNER, SETGID, SETUID]
    cleanCiliumState: [NET_ADMIN, SYS_ADMIN, SYS_RESOURCE]

# LoadBalancer IPs on the flat LAN (10.0.12.0/24)
l2announcements:
  enabled: true
k8sClientRateLimit:
  qps: 10
  burst: 20

# Ingress: Gateway API
gatewayAPI:
  enabled: true
  enableAlpn: true
  enableAppProtocol: true
```

Where these values come from:

- **Talos block**: the [Talos Cilium guide](https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium.md). `SYS_MODULE` is absent because Talos doesn't allow workloads to load kernel modules. `cgroup.*` is set because Talos already mounts cgroupv2. `k8sServiceHost`/`Port` point at KubePrism.
- **`l2announcements.enabled` + `k8sClientRateLimit`**: the [L2 announcements docs](https://docs.cilium.io/en/stable/network/l2-announcements/) ([source for v1.20.5](https://github.com/cilium/cilium/blob/v1.20.5/Documentation/network/l2-announcements.rst)). The feature requires kube-proxy replacement. The docs warn that sizing the client rate limit "is important when using this feature due to increased API usage". The default is 5 QPS with bursts up to 10, and the sizing formula is `QPS = #services × (1 / leaseRenewDeadline)`. With only a handful of LoadBalancer services (the Gateway and maybe a few more), 10/20 leaves plenty of headroom. Recompute if many services get their own IP. `devices` isn't set, so every device is eligible for announcements.
- **`gatewayAPI.*`**: the [Talos Cilium guide](https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium.md), with `enableAlpn` for gRPC over TLS. The [Cilium Gateway API docs](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api/) require `kubeProxyReplacement=true`.
- **Other variants**: cluster-template uses `127.0.0.1`, adds `PERFMON`/`BPF` and `bpf.hostLegacyRouting` ([helmrelease](https://github.com/onedr0p/cluster-template/blob/main/template/config/kubernetes/apps/kube-system/cilium/app/helmrelease.yaml.j2)). Jonas uses `securityContext.privileged: true` ([post 2](https://jonashietala.se/blog/2026/05/22/talos_linux_on_proxmox_with_terraform)).
- **`k8sServiceHost: localhost`, not `127.0.0.1`.** Both reach KubePrism, which listens on the host's loopback. I kept the Talos guide's value because the guide is the source for every other Talos-specific setting here. On the built cluster the agents connect fine (`cilium-dbg status`: `Kubernetes: Ok 1.37 (v1.37.2)`).
- **Capabilities.** The Talos-guide set was enough. Without `PERFMON`/`BPF` or `bpf.hostLegacyRouting`, all three agents come up `OK` with `KubeProxyReplacement: True`, so I didn't add them.

**Versions.** The Cilium 1.20.5 chart is at `oci://quay.io/cilium/charts/cilium` (`helm show chart` reports `version: 1.20.5`, `kubeVersion: '>= 1.21.0-0'`). The cluster runs Kubernetes 1.37.2, which Cilium 1.20 doesn't e2e-test: its [compatibility page](https://github.com/cilium/cilium/blob/v1.20.5/Documentation/network/kubernetes/compatibility.rst) lists 1.33–1.36, and says untested versions "depend on the forward / backward compatibility offered by Kubernetes". 1.37 is listed only on `main` (Cilium 1.21, still at `1.21.0-pre.4` on 2026-11-18). 1.20.5 works on this cluster (status checks and the connectivity test below), so move to 1.21 once it's released rather than running a pre-release.

The IP pool and L2 policy are Cilium CRs, not Helm values. They arrive with the Cilium app (step 1 of the [migration](/kubernetes/migration)) as `kubernetes/apps/kube-system/cilium/app/networks.yaml`, with addresses from the [network map](/kubernetes/intro#network-map). The shared Gateway is a separate app ([below](#the-shared-gateway)):

```yaml
---
apiVersion: cilium.io/v2
kind: CiliumLoadBalancerIPPool
metadata:
  name: lan
spec:
  blocks:
    - start: "10.0.12.1"
      stop: "10.0.12.254"
---
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata:
  name: lan
spec:
  loadBalancerIPs: true
  nodeSelector:
    matchLabels:
      kubernetes.io/os: linux
```

- **Pool range.** A `start`/`stop` block is explicit about `.1`–`.254`. By default LB IPAM "uses all IPs in a given CIDR". `allowFirstLastIPs: "No"` would reserve `.0` and `.255`, but that setting "only applies to blocks specified with `.spec.blocks[].cidr`", not to `start`/`stop` blocks ([LB IPAM docs](https://github.com/cilium/cilium/blob/v1.20.5/Documentation/network/lb-ipam.rst)). Inside a flat `/16`, `10.0.12.0` and `10.0.12.255` are ordinary host addresses anyway, but leaving them out avoids surprises. The `cilium.io/v2` API version follows [cluster-template's `networks.yaml`](https://github.com/onedr0p/cluster-template/blob/main/template/config/kubernetes/apps/kube-system/cilium/app/networks.yaml.j2).
- **No `serviceSelector`** means every LoadBalancer Service can get an IP from the pool.
- **L2 policy.** It announces LoadBalancer IPs via ARP. `interfaces` is omitted ("if not specified all interfaces will be used"). The fields and the `cilium.io/v2alpha1` version come from the [L2 announcements docs](https://github.com/cilium/cilium/blob/v1.20.5/Documentation/network/l2-announcements.rst). L2 mode has no load balancing before the cluster: one node answers ARP for each IP. Everything is one flat L2 segment, so BGP isn't needed.

### The shared Gateway

Every app is exposed through one Cilium `Gateway`, `main` in `kube-system`, on `10.0.12.1`. It terminates TLS with one wildcard certificate, so an app needs only an `HTTPRoute` ([Routing an app](/kubernetes/flux/repository-architecture#routing-an-app)). It is step 6 of the [migration](/kubernetes/migration), the app `kubernetes/apps/kube-system/gateway/`, which `dependsOn` `cilium`, `gateway-api-crds` and `cluster-issuer` (in `cert-manager`). It uses `postBuild.substituteFrom: cluster-secrets` for `${SECRET_DOMAIN}`. The listener layout and wildcard certificate follow Jonas ([post 6](https://jonashietala.se/blog/2026/08/06/domains_certificates_and_dns)).

`app/gateway.yaml`:

```yaml
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: main
spec:
  gatewayClassName: cilium
  addresses:
    - type: IPAddress
      value: 10.0.12.1
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      tls:
        mode: Terminate
        certificateRefs:
          - name: ${SECRET_DOMAIN/./-}-tls
      allowedRoutes:
        namespaces:
          from: All
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: Same
```

`app/certificate.yaml` and `app/httproute-redirect.yaml`:

```yaml
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard
spec:
  secretName: ${SECRET_DOMAIN/./-}-tls
  issuerRef:
    group: cert-manager.io
    kind: ClusterIssuer
    name: cloudflare-cluster-issuer
  dnsNames:
    - ${SECRET_DOMAIN}
    - "*.${SECRET_DOMAIN}"
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: http-to-https
spec:
  parentRefs:
    - name: main
      sectionName: http
  rules:
    - filters:
        - type: RequestRedirect
          requestRedirect:
            scheme: https
            statusCode: 301
```

How the Gateway gets its IP:

- **Use `spec.addresses`, not an annotation.** Cilium's docs show `spec.addresses` with `type: IPAddress` as the way to pin a Gateway's IP through LB IPAM. The `io.cilium/lb-ipam-ips` annotation placed in `spec.infrastructure.annotations` still works and overrides `spec.addresses`, but Cilium plans to deprecate it and later ignore it ([Gateway addresses docs](https://github.com/cilium/cilium/blob/v1.20.5/Documentation/network/servicemesh/gateway-api/addresses.rst)). On the built cluster, `spec.addresses` alone was enough. Cilium created the Service `kube-system/cilium-gateway-main` (`LoadBalancer`, ports 80 and 443) with `10.0.12.1`. I didn't test whether the `lbipam.cilium.io/ips` Service annotation passes through `spec.infrastructure.annotations`, because nothing needs it.
- **`10.0.12.1` is the pool's first IP.** The LB IPAM docs say not to request the first or last IP of a pool ([LB IPAM docs](https://github.com/cilium/cilium/blob/v1.20.5/Documentation/network/lb-ipam.rst)). That warning is about network/broadcast addresses in CIDR blocks. `10.0.12.1` is neither, and Cilium does assign it: in the [L2 check](#checking-cilium), a Service annotated `lbipam.cilium.io/ips: "10.0.12.1"` got exactly that IP from the `start`/`stop` pool, and the Gateway got it too.

Decisions:

- **HTTP redirects to HTTPS.** The `http` listener accepts routes only from `kube-system` (`from: Same`), where the one `HTTPRoute` above answers every plain-HTTP request, for any hostname, with a `301` to HTTPS. Apps can't attach to it by mistake, so they never serve plaintext. They still set `sectionName: https`. Cilium writes the port into the redirect: `http://x.<domain>/foo?x=1` → `location: https://x.<domain>:443/foo?x=1`. That's valid and browsers follow it, but it isn't the clean URL the Gateway API spec recommends (it says implementations SHOULD NOT add `:443` for `https`).
- **SANs: the apex and `*.<domain>`.** The apex is included so the bare domain can be routed later. No second-level wildcards: the `*.cluster.<domain>` names (Postgres, Redis, nodes) are outside Kubernetes and don't go through the Gateway. A wildcard covers only one label, so `a.b.<domain>` would need its own SAN.
- **The Secret name is derived from the domain**, `${SECRET_DOMAIN/./-}-tls` (cluster-template's pattern), so the domain stays in `cluster-secrets` and out of Git. Flux's `envsubst` replaces the first `.`, which gives `lorenzolab-com-tls`.
- **`timeout: 10m`.** The first issuance runs two DNS-01 challenges (the apex and the wildcard both validate through the TXT record `_acme-challenge.<domain>`, and cert-manager ran them one after the other), about 2.5 minutes in total. The default 5 minutes left too little margin.

### Health-checking the Gateway

kstatus doesn't understand a `Gateway`'s conditions, so `ks.yaml` lists the `Certificate` and the `Gateway` in `healthChecks`, and adds `healthCheckExprs` for the `Gateway`:

```yaml
healthCheckExprs:
  - apiVersion: gateway.networking.k8s.io/v1
    kind: Gateway
    current: >-
      status.conditions.filter(e, e.type == 'Programmed').all(e, e.status == 'True')
      && has(status.listeners)
      && status.listeners.all(l, l.conditions.filter(c, c.type == 'Programmed').all(c, c.status == 'True'))
    failed: >-
      status.conditions.filter(e, e.type == 'Accepted').all(e, e.status == 'False' && e.reason != 'ListenersNotValid')
```

What Cilium 1.20.5 actually reports, checked 2026-11-19:

- **Waiting for the certificate.** The `Certificate` and the `Gateway` are applied together, so for the first couple of minutes the Secret doesn't exist. Cilium marks the `https` listener `ResolvedRefs=False/InvalidCertificateRef`, `Accepted=False/Invalid`, `Programmed=False/Pending`. `main` itself stayed `Accepted=True`, because the `http` listener was valid. It went `Programmed=True` (Gateway and both listeners) as soon as the certificate was issued.
- **No valid listener at all.** A throwaway Gateway with only an HTTPS listener and a missing Secret reported `Accepted=False` and `Programmed=False`, both `ListenersNotValid/NoAcceptedListeners`. That's also a wait, not a failure, hence the `reason` exclusion in `failed`. Any other `Accepted=False` (a wrong `gatewayClassName`, say) fails the health check at once instead of running out the timeout.
- **`current` also requires every listener to be `Programmed`**, so a Gateway that is half up (one listener still pending) doesn't count as healthy.

### Checking the Gateway

On the built cluster (2026-11-19), after pushing the app and `just bootstrap::reconcile`:

```bash
flux get kustomizations -A                         # gateway: Ready ("Health check passed in 2m40s")
kubectl -n kube-system get certificate             # wildcard  READY True  SECRET lorenzolab-com-tls
kubectl -n kube-system get gateway main            # cilium  10.0.12.1  PROGRAMMED True
kubectl -n kube-system get svc cilium-gateway-main # LoadBalancer  EXTERNAL-IP 10.0.12.1
```

- **Ordering.** kustomize-controller logged "Dependencies do not meet ready condition, retrying in 30s", then "All dependencies are ready", so `dependsOn` held it back until `cilium`, `gateway-api-crds` and `cluster-issuer` were Ready.
- **The certificate** came from the production issuer (`cloudflare-cluster-issuer`). Its order was `valid` after two DNS-01 challenges for the domain. Issuer `C=US; O=Let's Encrypt; CN=YR1`, `CN=<domain>`, valid 90 days.
- **End to end, with `curl --resolve`, no DNS record.** I deployed a throwaway `traefik/whoami` in a namespace `echo-test`, with an `HTTPRoute` on `sectionName: https` for `echo-test.<domain>`. From the workstation on the LAN:
  - `curl -v --resolve echo-test.<domain>:443:10.0.12.1 https://echo-test.<domain>/` answered `HTTP/2 200` from the pod, with `subjectAltName: "echo-test.<domain>" matches cert's "*.<domain>"` and `X-Forwarded-Proto: https`.
  - `curl -I` on `http://` gave `301` to `https://…:443/foo?x=1`, path and query kept.
  - A hostname with no route, and the apex (no route yet), both got `404` from the Gateway over valid TLS.

  Then I deleted the namespace. I didn't create a DNS record: DNS automation is still [open](/kubernetes/migration#open-questions).

### Checking Cilium

What I checked after `just bootstrap::crds` and `just bootstrap::helmfile` (then called `cilium`) on the built cluster (2026-11-18):

```bash
kubectl get nodes                                  # all Ready
kubectl -n kube-system get pods                    # coredns Running, no kube-proxy
cilium status --wait                               # OK; 3/3 agents, 3/3 envoy, 2/2 operator
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep KubeProxyReplacement   # True (on each agent)
kubectl get gatewayclass cilium                    # ACCEPTED True
cilium connectivity test --namespace-labels pod-security.kubernetes.io/enforce=privileged
```

- **The connectivity test needs `--namespace-labels`.** Talos enforces the `baseline` Pod Security Standard on every namespace by default. The test's pods add `NET_RAW` and use `hostNetwork`/`hostPort`, so without a `privileged` label on the test namespaces, admission rejects every pod and the test hangs at "Waiting for deployment cilium-test-1/client". The flag labels all the test namespaces (`cilium-test-1`, `cilium-test-ccnp1`, `cilium-test-ccnp2`). Delete them afterwards: `kubectl get ns -o name | grep cilium-test | xargs kubectl delete`. Real apps that need more than `baseline` (Longhorn, for instance) need the same label on their namespace.
- **Result:** all 83 tests (721 actions) passed, 49 skipped, in about 20 minutes. The skips fall into these groups, none of them a problem:
  - *Unsafe tests* (they change node state; they only run with `--include-unsafe-tests`): the `*-from-outside` tests, `from-cidr-host-netns`, egress gateway, BGP, multicast, host firewall, strict-mode/IPsec encryption, `local-redirect-policy-with-node-dns`.
  - *Need a node without Cilium*: `north-south-loadbalancing*`. Every node runs Cilium.
  - *Features not enabled*: encryption, mutual auth (SPIFFE), Cilium's Ingress controller (Gateway API is used instead), the L7 load balancer, local redirect policy, ztunnel, `cidr-match-nodes`, `k8s-cluster-network-policy`. Two old encryption tests only run on Cilium < 1.18.
  - *Not applicable*: ClusterMesh tests and `echo-ingress-l7-via-hostport` ("skipped by condition"), and the `pod-to-controlplane-host*`/`pod-to-k8s-on-controlplane*` tests ("k8s localhost tests excluded", because the API server is reached through KubePrism on localhost).
- **L2 announcements, by hand.** I applied the pool and L2 policy above, plus a test pod behind a `type: LoadBalancer` Service annotated `lbipam.cilium.io/ips: "10.0.12.1"`. The Service got `10.0.12.1` in about 5 seconds, a `cilium-l2announce-l2-test.echo` Lease appeared in `kube-system` (held by `talos-2`), and `curl http://10.0.12.1/` from a laptop on the LAN answered. The laptop's ARP entry for `10.0.12.1` was `talos-2`'s MAC. Then I deleted everything, since the real pool and policy arrive through Flux. Once Flux had applied them, I repeated the test without pinning an IP. The Service got `10.0.12.1`, the first address in the pool, and the Lease was again held by `talos-2`. It answered both from the workstation and from a phone on the LAN. The pool shows `CONFLICTING False` and `IPS AVAILABLE 254`.

## 4. Flux takes over

Once `flux-instance` is installed, the Flux Operator deploys the controllers. Because `spec.sync` is set, it also creates a `GitRepository` and a `Kustomization`, both named `flux-system`, pointing at `kubernetes/apps` ([FluxInstance docs](https://fluxoperator.dev/docs/crd/fluxinstance/)). The instance's kustomize patches add SOPS decryption and HelmRelease defaults to that Kustomization and every child ([Flux](/kubernetes/flux/intro#the-fluxinstance)).

```bash
kubectl get nodes                               # Ready once Cilium is up
kubectl -n flux-system get fluxinstance flux
flux get kustomizations -A                      # flux-system: Ready
```

### Checking Flux

What I checked after `just bootstrap::apps` on the cluster (2026-11-18):

- **The instance.** `kubectl -n flux-system get fluxinstance flux` was `READY True`, "Reconciliation finished in 1m24s", at `v2.10.0`. `flux-operator` and the four controllers (`source`, `kustomize`, `helm`, `notification`) were `1/1`.
- **The sync.** `flux get sources git -A` and `flux get kustomizations -A` both showed `flux-system` Ready at the pushed `main` commit.
- **The patches landed.** `kustomize-controller` runs with `--sops-age-secret=sops-age`, and the `flux-system` Kustomization has `decryption.provider: sops`, `deletionPolicy: WaitForTermination` and the child-Kustomization patch.
- **Idempotency.** A second `just bootstrap::apps` re-applied the namespace and the two secrets with no change, and all three Helm releases stayed at revision 1.
- **Sync, SOPS and prune.** I committed a throwaway SOPS-encrypted Secret under `kubernetes/apps/` (encrypted by rule 3, so GPG + age). After `just bootstrap::reconcile` it was in the cluster, decrypted. Removing it from Git and reconciling again deleted it, since the generated Kustomization has `prune: true`.

Cilium, the Flux Operator and the FluxInstance are still plain Helm releases at this point. Flux manages them only once their `HelmRelease`s are added under `kubernetes/apps/` with the same names and namespaces. helm-controller then takes over the existing releases; cluster-template relies on this ("After this bootstrap phase, Flux is ready to take over management", [apps.yaml](https://github.com/onedr0p/cluster-template/blob/main/template/config/bootstrap/helmfile/apps.yaml.j2)).

### What the takeover does (Cilium, 2026-11-18)

Cilium was the first release Flux took over (step 1 of the [migration](/kubernetes/migration)). Its `HelmRelease` has the same name and namespace as the helmfile release, and values identical to `values/cilium.yaml`. What happened:

- **helm-controller upgrades the release in place.** `helm -n kube-system history cilium` shows revision 1 (helmfile, `cilium-1.20.5`, "Install complete") `superseded`, and revision 2 `deployed` as `cilium-1.20.5+873a782bf106`, "Upgrade complete". There was no uninstall or reinstall. The `cilium` Kustomization and HelmRelease went Ready, and the HelmRelease reports `1.20.5+873a782bf106`.
- **The chart version gains the OCI digest.** With `chartRef` to an `OCIRepository`, helm-controller stores the chart as `<version>+<first 12 hex chars of the digest>`. The chart's `helm.sh/chart` label then becomes `cilium-1.20.5_873a782bf106`.
- **All Cilium pods rolled once.** That label is in the pod templates of the `cilium` and `cilium-envoy` DaemonSets and the `cilium-operator` Deployment, so all 8 pods were replaced within about 15 seconds. They came back with 0 restarts. `cilium status` was `OK` for the agents, operator and Envoy, with 8/8 pods managed by Cilium, and `cilium-dbg status` still showed `KubeProxyReplacement: True`. This happens once, at the takeover. Later reconciles with an unchanged digest don't roll anything.
- **No values were lost.** The only difference in `helm get values` between revisions 1 and 2 is `upgradeCompatibility: "1.20"`. It was added to `values/cilium.yaml` after the install and never applied by helmfile, so the takeover applied it.
- **Flux labels every object.** The rendered manifest gains `helm.toolkit.fluxcd.io/name: cilium` and `helm.toolkit.fluxcd.io/namespace: kube-system` on each object (32 of them). The rest of the manifest diff is helm-controller's YAML formatting, such as quoting and list indentation.

### What the takeover does (Flux, 2026-11-19)

Step 2 of the [migration](/kubernetes/migration) added `flux-operator` and `flux-instance` under `kubernetes/apps/flux-system/` ([#180](https://github.com/lorenzorapetti/homelab/issues/180), layout on the [Flux page](/kubernetes/flux/intro#flux-manages-itself)). After the push and `just bootstrap::reconcile`:

- **Same in-place upgrade as Cilium.** `helm -n flux-system history` shows revision 1 (helmfile, "Install complete") `superseded` and revision 2 (`flux-operator-0.62.1+1135514a01cc`, `flux-instance-0.62.1+38215516080c`, "Upgrade complete") `deployed` for both releases. `flux get hr -n flux-system` shows both Ready, and the FluxInstance `flux` stayed Ready at `v2.10.0`.
- **Order.** The `flux-instance` Kustomization reported `DependencyNotReady` until `flux-operator` passed its health check (30s), then took over its release in 5s.
- **Only the operator pod rolled.** The new `flux-operator` pod started 11 seconds before the old one was stopped, so there was always one running. The four controllers kept their pods from the original install. The FluxInstance chart renders only the `FluxInstance` object, and its spec didn't change, so the operator had nothing to roll out.
- **Reconciling again changes nothing.** A plain `flux reconcile hr … --with-source` of both releases left them at revision 2.

### Flux upgrading itself

helm-controller now upgrades the release that defines helm-controller. I tested this with a forced upgrade of each release with unchanged values (`flux reconcile hr -n flux-system <name> --force`). Each produced revision 3, "Upgrade complete", in a few seconds, and no flux-system pod restarted. With unchanged values the rendered objects are identical, so there was nothing to roll.

That test doesn't cover the risky case: a commit that changes `distribution.version` or the operator's controller images. Then helm-controller applies the new `FluxInstance` and waits for it to be Ready. Meanwhile the operator replaces the controllers, including the helm-controller pod that is doing the waiting. **Unverified:** whether the new helm-controller picks up the release cleanly, or finds it stuck in `pending-upgrade`. For the next Flux upgrade (procedure in [Upgrades](/kubernetes/upgrades#flux)):

- Bump the operator chart and the Flux minor in **separate commits**, as the Flux docs already require, so only one thing changes at a time.
- Afterwards, check `helm -n flux-system history flux-instance`. If the last revision is `pending-upgrade`, run `flux reconcile hr -n flux-system flux-instance --force`, or roll back with `helm -n flux-system rollback flux-instance <revision>`, and update this section with what happened.

### `just bootstrap::apps` after a takeover

On a fresh cluster, `just bootstrap::apps` installs the releases and Flux then takes them over as above. On a running cluster where Flux owns the releases, it is **not a no-op**. Chart, version and values are now identical, because the helmfile reads them from the Flux manifests. But the manifests helm-controller stored still differ in two ways:

- **The chart version carries the OCI digest** (`0.62.1+1135514a01cc`), and so does the `helm.sh/chart` label. That label is in the pod templates, so a helmfile upgrade would roll the pods.
- **Every object carries `helm.toolkit.fluxcd.io/name` and `/namespace` labels.**

`just bootstrap::diff` therefore shows changes to most objects. Most of the diff's lines are helm-controller's YAML formatting (quoting, list indentation). I compared the live manifests with the helmfile render semantically, parsed as YAML with those labels removed (2026-11-19):

- `flux-operator` (13 objects) and `flux-instance` (1 object) are identical.
- Cilium has the same 32 objects. The only differences are equivalent spellings: `defaultMode: 0400` stored as `256`, and `annotations: null` or `labels: {}` stored as absent. Render with `--validate`, or Cilium leaves out the objects it only adds when the cluster serves the API (the `GatewayClass` and the `ValidatingAdmissionPolicy`).

Since [#189](https://github.com/lorenzorapetti/homelab/issues/189) the diff also removes the `flux-operator` ServiceMonitor: `bootstrap/helmfile/apps.yaml` turns it off because the CRD doesn't exist on a fresh cluster ([Monitoring Flux](/kubernetes/flux/monitoring#the-servicemonitor-crd-and-the-bootstrap)).

So on the running cluster, use `just bootstrap::diff` to compare, and expect those differences. Don't run `just bootstrap::apps` or `just bootstrap::helmfile`: helm-controller would notice the release changed outside Flux and upgrade it back, rolling the pods twice. I haven't checked whether helm-controller can turn off the digest suffix.

## The justfile

Like Jonas ([post 3](https://jonashietala.se/blog/2026/05/28/just_command_runner_documentation)), I use [just](https://just.systems/) with one module per area. Syntax notes, all from the [just README](https://github.com/casey/just/blob/master/README.md):

- **Module directories.** `mod NAME 'PATH'` loads a module, and a path can point to a directory containing `mod.just`. Recipes in a submodule run "with the working directory set to the directory containing the submodule source file".
- **Root paths.** `justfile_directory()` always returns the root justfile's directory, even inside modules.
- **Other syntax.** `/` joins paths, `export` passes a variable to recipes as an environment variable, and `[doc(...)]`/`[confirm]` are recipe attributes ([attributes](https://just.systems/man/en/attributes.html)).
- **Calling recipes.** Module recipes are called as `just talos::create` or `just talos create`. Modules are stable since just 1.31.0 ([modules](https://just.systems/man/en/modules.html)).

`justfile`:

```just
mod tf 'infrastructure/mod.just'
mod talos 'talos/mod.just'
mod bootstrap 'bootstrap/mod.just'

[private]
default:
    @just --list --list-submodules

[doc("Empty Proxmox → bare Talos + Cilium + Flux skeleton")]
full: tf::apply talos::create bootstrap::apps
```

`full` chains the three modules, but it hasn't been run end to end yet: the cluster was built step by step.

`infrastructure/mod.just` (state and Proxmox token kept SOPS-encrypted, as in Jonas's `tf::apply`). This is the built version:

```just
init *args:
    terraform init {{ args }}

plan *args: (_run "plan" args)
apply *args: (_run "apply" args)

[confirm("Destroy all Talos VMs?")]
destroy *args: (_run "destroy" args)

output *args: (_run "output" args)

[private]
_run command *args:
    #!/usr/bin/env bash
    set -euo pipefail
    umask 077
    if [[ -e terraform.tfstate ]]; then
      echo "error: plaintext terraform.tfstate already exists (an earlier run was interrupted?)." >&2
      exit 1
    fi
    TF_VAR_proxmox_api_token="$(sops decrypt --extract '["proxmox_api_token"]' secrets.sops.yaml)"
    export TF_VAR_proxmox_api_token
    if [[ -f terraform.tfstate.sops.json ]]; then
      sops decrypt --input-type json --output-type json terraform.tfstate.sops.json > terraform.tfstate
    fi
    reencrypt() {
      [[ -f terraform.tfstate ]] || return 0
      if sops encrypt --filename-override terraform.tfstate.sops.json \
          --input-type json --output-type json terraform.tfstate > terraform.tfstate.sops.json.tmp; then
        mv terraform.tfstate.sops.json.tmp terraform.tfstate.sops.json
        rm -f terraform.tfstate terraform.tfstate.backup
      else
        rm -f terraform.tfstate.sops.json.tmp
        return 1   # keep the plaintext state rather than lose it
      fi
    }
    trap reencrypt EXIT
    terraform {{ command }} {{ args }}
```

Compared with the first draft (a single `trap '... > terraform.tfstate.sops.json && rm ...'`), the encryption writes to a temp file first. A failed `sops encrypt` therefore can't truncate the committed state and then delete the plaintext copy. The trap is also set only after the state has been decrypted completely, so a failed decrypt never re-encrypts a partial file over the good one.

`talos/mod.just`:

```just
export TALOSCONFIG := justfile_directory() / "talos" / "talosconfig"
export KUBECONFIG := justfile_directory() / "kubeconfig"

[doc("Generate secrets (once), apply config (diff + confirm), bootstrap etcd, write talosconfig/kubeconfig")]
create: _secrets && configs
    topf apply --auto-bootstrap

configs:   # topf talosconfig / kubeconfig --validity 8760h, via a temp file, umask 077
    ...

apply *args:
    topf apply {{ args }}

diff *args:
    topf apply --dry-run {{ args }}

upgrade *args:
    topf upgrade {{ args }}

[doc("Upgrade Kubernetes to kubernetesVersion from topf.yaml")]
upgrade-k8s:
    talosctl --nodes 10.0.11.1 upgrade-k8s --to "$(yq '.kubernetesVersion' topf.yaml)"

[confirm("Reset ALL nodes to maintenance mode? This destroys the cluster.")]
reset:
    topf reset --full=false --confirm=false --wait-for-maintenance

_secrets:  # topf secrets --confirm=false > /dev/null, then abort unless sops filestatus says encrypted
    ...
```

This is abridged; the full file is [`talos/mod.just`](https://github.com/lorenzorapetti/homelab/blob/main/talos/mod.just), explained in [Install Talos](/kubernetes/getting-started/install-talos#create-the-cluster). `apply` keeps topf's confirmation, so `create` always shows the diff before touching the nodes.

`bootstrap/mod.just` (built; `[doc]` attributes trimmed). `helmfile` was called `cilium` while the file held only Cilium:

```just
export KUBECONFIG := justfile_directory() / "kubeconfig"

[doc("Secrets, Gateway API CRDs, Cilium + Flux. The YubiKey must be plugged in")]
apps: wait-for-nodes secrets crds helmfile

wait-for-nodes:
    until [[ -n "$(kubectl get nodes -o name --request-timeout=10s 2>/dev/null)" ]]; do sleep 5; done

secrets: wait-for-nodes
    kubectl create namespace flux-system --dry-run=client -o yaml | kubectl apply --server-side -f -
    sops decrypt sops-age.sops.yaml | kubectl apply --server-side -f -
    sops decrypt github-deploy-key.sops.yaml | kubectl apply --server-side -f -

crds: wait-for-nodes
    tag="$(yq 'select(.kind == "GitRepository") | .spec.ref.tag' ../kubernetes/apps/kube-system/gateway-api-crds/ks.yaml)" \
      && kubectl apply --server-side -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${tag}/experimental-install.yaml"

diff:
    helmfile --file helmfile/apps.yaml diff

helmfile: wait-for-nodes
    helmfile --file helmfile/apps.yaml apply --hide-notes --skip-diff-on-install

reconcile:
    flux --namespace flux-system reconcile kustomization flux-system --with-source
```

Flux syncs `main`, so push the commit that creates `kubernetes/apps/` before running `apps`: until then the `flux-system` Kustomization can't find its path.

Notes on the justfile:

- **`helmfile apply`, not `sync`.** cluster-template uses `sync`, which upgrades every release on every run, so each run adds a Helm revision even when nothing changed. `apply` runs `helm diff` first and upgrades only the releases that differ, so re-running `just bootstrap::helmfile` on an unchanged cluster is a no-op (every release stays at revision 1). That holds only until Flux takes a release over ([see above](#just-bootstrapapps-after-a-takeover)). This needs the [helm-diff](https://github.com/databus23/helm-diff) plugin, which `devenv.nix` bundles by wrapping `helm` with `wrapHelm` and pointing `helmfile` at the same plugin directory. `--skip-diff-on-install` stops the first install from printing the whole chart as a diff.
- **Tools.** `devenv.nix` provides `helm` (with helm-diff), `helmfile`, the `cilium` CLI and the `flux` CLI (`fluxcd`, v2.10.0), alongside `kubectl`.

- **Where the commands come from.** The topf invocations follow cluster-template's `bootstrap:talos` tasks, including the 8760h kubeconfig. Unlike cluster-template, `apply` doesn't pass `--confirm=false`, so the diff is always shown first. `upgrade-k8s` mirrors its Talos task ([bootstrap tasks](https://github.com/onedr0p/cluster-template/blob/main/template/config/bootstrap/mise.toml), [talos tasks](https://github.com/onedr0p/cluster-template/blob/main/template/config/talos/mise.toml)).
- **The Terraform state rule.** The state is encrypted as JSON (`--input-type json`), which needs its own `infrastructure/` rule in [`.sops.yaml`](/kubernetes/sops#sopsyaml). `--filename-override` is the right flag in sops 3.13: "Use this filename instead of the provided argument for loading configuration". Run from `infrastructure/`, `--filename-override terraform.tfstate.sops.json` picks up rule 2, which encrypts to both the GPG key and the age key. I checked this by encrypting a dummy file.
- **The root `justfile` exports nothing**, since each module sets the variables it needs. **Unverified:** whether a root-level `export` would reach module recipes. The README only documents that environment *files* from parent modules are visible in child modules.
