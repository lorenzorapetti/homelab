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
| `bootstrap/helmfile/apps.yaml`, `bootstrap/helmfile/values/*.yaml` | Releases and values for Cilium, flux-operator, flux-instance |
| `kubernetes/apps/kustomization.yaml` | An empty Kustomize file (`resources: []`), so the path exists in Git |

There is no `kubernetes/flux/cluster/ks.yaml`. The FluxInstance syncs `kubernetes/apps` directly ([Repository Architecture](/kubernetes/flux/repository-architecture)). Git doesn't track empty directories, so `kubernetes/apps/` needs that one file. **Unverified:** that kustomize-controller treats `resources: []` as "nothing to apply" and reports Ready. Check this on the first reconcile.

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
- **The pull secret is named `flux-system`**, matching the existing deploy key setup. It uses the `identity`/`known_hosts` keys of [cluster-template's deploy key](https://github.com/onedr0p/cluster-template/blob/main/template/config/bootstrap/deploy-key.sops.yaml.j2).

## 2. Gateway API CRDs

Cilium's Gateway API controller needs the Gateway API CRDs **before** Cilium starts. Cilium 1.20 documents Gateway API **v1.6.3** and requires `TLSRoute`. Either channel works, but experimental features need the experimental channel ([Cilium Gateway API docs](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api/)). The `ExternalAuth` HTTPRoute filter (GEP-1494, status *Experimental*, [GEP](https://gateway-api.sigs.k8s.io/geps/gep-1494/)) is the cleanest way to put Authentik in front of apps (see [Authentik forward auth](/kubernetes/migration#authentik-forward-auth-with-cilium-gateway)), so install the **experimental** channel:

```bash
kubectl apply --server-side \
  -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.3/experimental-install.yaml
```

Both `standard-install.yaml` and `experimental-install.yaml` are assets of the [v1.6.3 release](https://github.com/kubernetes-sigs/gateway-api/releases/tag/v1.6.3). Jonas applies the CRDs first for the same reason ([post 2](https://jonashietala.se/blog/2026/05/22/talos_linux_on_proxmox_with_terraform)). Later, Flux takes them over as an app: a `GitRepository` on `kubernetes-sigs/gateway-api` at `v1.6.3` plus a Kustomization on `config/crd/experimental`. **Unverified:** that directory name; check the repo tree at that tag.

## 3. helmfile: Cilium, Flux Operator, FluxInstance

`bootstrap/helmfile/apps.yaml`:

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/helmfile
helmDefaults:
  cleanupOnFail: true
  forceConflicts: true
  wait: true
  waitForJobs: true

releases:
  - name: cilium
    namespace: kube-system
    chart: oci://quay.io/cilium/charts/cilium
    version: 1.20.5
    values: ["./values/cilium.yaml"]

  - name: flux-operator
    namespace: flux-system
    chart: oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator
    version: 0.62.1
    needs: ["kube-system/cilium"]

  - name: flux-instance
    namespace: flux-system
    chart: oci://ghcr.io/controlplaneio-fluxcd/charts/flux-instance
    version: 0.62.1
    values: ["./values/flux-instance.yaml"]
    needs: ["flux-system/flux-operator"]
```

The order, `needs` chain and `helmDefaults` come from [cluster-template's `apps.yaml`](https://github.com/onedr0p/cluster-template/blob/main/template/config/bootstrap/helmfile/apps.yaml.j2), minus `coredns`, `spegel` and `cert-manager`. CoreDNS stays Talos-managed, and cert-manager arrives later as an app. The chart URLs are the ones cluster-template's `ocirepository.yaml` files use. The Flux Operator docs give the same `oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator` source ([operator install](https://github.com/controlplaneio-fluxcd/flux-operator/blob/main/docs/guides/operator/operator-install.md)). `values/flux-instance.yaml` is on the [Flux page](/kubernetes/flux/intro#the-fluxinstance).

### Later: one source of truth for values

Once Cilium and Flux are apps in `kubernetes/apps/`, switch the helmfile to cluster-template's trick of **reading chart, version and values from the Flux manifests**:

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

These are verbatim from cluster-template ([default.yaml](https://github.com/onedr0p/cluster-template/blob/main/template/config/bootstrap/helmfile/default.yaml.j2), [release.yaml.gotmpl](https://github.com/onedr0p/cluster-template/blob/main/template/config/bootstrap/helmfile/templates/release.yaml.gotmpl.j2), [values.yaml.gotmpl](https://github.com/onedr0p/cluster-template/blob/main/template/config/bootstrap/helmfile/templates/values.yaml.gotmpl.j2)). Each release then uses `inherit: [{template: default}]`. This removes the duplicated Cilium values that Jonas couldn't avoid with ArgoCD ([post 5](https://jonashietala.se/blog/2026/07/23/gitops_with_argocd)).

### Cilium networking

`values/cilium.yaml`, which later becomes `kubernetes/apps/kube-system/cilium/app/helmrelease.yaml`:

```yaml
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

The IP pool, L2 policy and the shared Gateway are Cilium CRs, not Helm values. They arrive with the Cilium app (step 1 of the [migration](/kubernetes/migration)) as `kubernetes/apps/kube-system/cilium/app/networks.yaml`, with addresses from the [network map](/kubernetes/intro#network-map):

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

The shared Gateway, pinned to `10.0.12.1`:

```yaml
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: main
  namespace: kube-system
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
          - name: lorenzolab-com-tls
      allowedRoutes:
        namespaces:
          from: All
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All
```

How the Gateway gets its IP:

- **Use `spec.addresses`, not an annotation.** Cilium's docs show `spec.addresses` with `type: IPAddress` as the way to pin a Gateway's IP through LB IPAM. The `io.cilium/lb-ipam-ips` annotation placed in `spec.infrastructure.annotations` still works and overrides `spec.addresses`, but Cilium plans to deprecate it and later ignore it ([Gateway addresses docs](https://github.com/cilium/cilium/blob/v1.20.5/Documentation/network/servicemesh/gateway-api/addresses.rst)).
- **`lbipam.cilium.io/ips` is the Service annotation.** It is the current way to request IPs for a plain `Service`. The docs say not to request the first or last IP of a pool ([LB IPAM docs](https://github.com/cilium/cilium/blob/v1.20.5/Documentation/network/lb-ipam.rst)). The Gateway docs don't say whether that annotation passes through `spec.infrastructure.annotations` (**unverified**), which is one more reason to use `spec.addresses`.
- **`10.0.12.1` is the pool's first IP.** That warning is about network/broadcast addresses in CIDR blocks. `10.0.12.1` is neither, but if Cilium refuses to assign it, use `10.0.12.2`.

The listener layout and wildcard certificate follow Jonas ([post 6](https://jonashietala.se/blog/2026/08/06/domains_certificates_and_dns)). The certificate comes later with cert-manager.

## 4. Flux takes over

Once `flux-instance` is installed, the Flux Operator deploys the controllers. Because `spec.sync` is set, it also creates a `GitRepository` and a `Kustomization`, both named `flux-system`, pointing at `kubernetes/apps` ([FluxInstance docs](https://fluxoperator.dev/docs/crd/fluxinstance/)). The instance's kustomize patches add SOPS decryption and HelmRelease defaults to that Kustomization and every child ([Flux](/kubernetes/flux/intro#the-fluxinstance)).

```bash
kubectl get nodes                               # Ready once Cilium is up
kubectl -n flux-system get fluxinstance flux
flux get kustomizations -A                      # flux-system: Ready
```

Cilium, the Flux Operator and the FluxInstance are still plain Helm releases at this point. Flux manages them only once their `HelmRelease`s are added under `kubernetes/apps/` with the same names and namespaces. helm-controller then takes over the existing releases; cluster-template relies on this ("After this bootstrap phase, Flux is ready to take over management", [apps.yaml](https://github.com/onedr0p/cluster-template/blob/main/template/config/bootstrap/helmfile/apps.yaml.j2)).

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
    @just --list

[doc("Empty Proxmox → bare Talos + Cilium + Flux skeleton")]
full: tf::apply talos::create bootstrap::apps
```

`infrastructure/mod.just` (state and Proxmox token kept SOPS-encrypted, as in Jonas's `tf::apply`). This is the built version. Only the `tf` module exists so far, so today's root `justfile` has just `mod tf` and the `default` recipe:

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

[doc("Generate secrets (once), apply config, bootstrap etcd, write talosconfig/kubeconfig")]
create:
    topf secrets --confirm=false > /dev/null
    topf apply --auto-bootstrap --confirm=false
    topf talosconfig > "$TALOSCONFIG"
    topf kubeconfig --validity 8760h > "$KUBECONFIG"

apply *args:
    topf apply {{args}}

diff:
    topf apply --dry-run

upgrade *args:
    topf upgrade {{args}}

[doc("Upgrade Kubernetes to kubernetesVersion from topf.yaml")]
upgrade-k8s:
    talosctl --nodes 10.0.11.1 upgrade-k8s --to "$(yq '.kubernetesVersion' topf.yaml)"

[confirm("Reset ALL nodes to maintenance mode?")]
reset:
    topf reset --confirm=false
```

`bootstrap/mod.just`:

```just
export KUBECONFIG := justfile_directory() / "kubeconfig"

[doc("Secrets, Gateway API CRDs, Cilium + Flux. The YubiKey must be plugged in")]
apps: wait-for-nodes secrets crds helmfile

[private]
wait-for-nodes:
    until [[ -n "$(kubectl get nodes -o name --request-timeout=10s 2>/dev/null)" ]]; do sleep 5; done

secrets:
    kubectl create namespace flux-system --dry-run=client -o yaml | kubectl apply --server-side -f -
    sops decrypt sops-age.sops.yaml | kubectl apply --server-side -f -
    sops decrypt github-deploy-key.sops.yaml | kubectl apply --server-side -f -

crds:
    kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.3/experimental-install.yaml

helmfile:
    helmfile --file helmfile/apps.yaml sync --hide-notes

[doc("Force Flux to pull the repo now")]
reconcile:
    flux --namespace flux-system reconcile kustomization flux-system --with-source
```

Notes on the justfile:

- **Where the commands come from.** The topf invocations follow cluster-template's `bootstrap:talos` tasks, including `--confirm=false` for non-interactive runs and the 8760h kubeconfig. `upgrade-k8s` mirrors its Talos task ([bootstrap tasks](https://github.com/onedr0p/cluster-template/blob/main/template/config/bootstrap/mise.toml), [talos tasks](https://github.com/onedr0p/cluster-template/blob/main/template/config/talos/mise.toml)).
- **The Terraform state rule.** The state is encrypted as JSON (`--input-type json`), which needs its own `infrastructure/` rule in [`.sops.yaml`](/kubernetes/sops#sopsyaml). `--filename-override` is the right flag in sops 3.13: "Use this filename instead of the provided argument for loading configuration". Run from `infrastructure/`, `--filename-override terraform.tfstate.sops.json` picks up rule 2, which encrypts to both the GPG key and the age key. I checked this by encrypting a dummy file.
- **The root `justfile` exports nothing**, since each module sets the variables it needs. **Unverified:** whether a root-level `export` would reach module recipes. The README only documents that environment *files* from parent modules are visible in child modules.
