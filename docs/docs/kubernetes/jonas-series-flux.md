---
sidebar_position: 7
sidebar_label: Jonas's series in Flux
---

# Jonas's series, translated to Flux

Jonas Hietala's [Modern Kubernetes homelab](https://www.jonashietala.se/series/kube-homelab/) series is the narrative I follow for the rebuild. He uses ArgoCD; I use Flux. Below is a summary of each published post (six as of 2026-11-18) and what the step looks like in this repo. The series index also lists four planned posts without links yet: *Data & Storage*, *Backups*, *SSO with Authentik* and *Loose ends*.

## Quick map

| Jonas (ArgoCD) | This repo (Flux) |
| --- | --- |
| Terraform (`bpg/proxmox` + `siderolabs/talos`) creates VMs, generates Talos config, bootstraps | Terraform (`bpg/proxmox` only) creates the VMs ([Deploying the infrastructure](/kubernetes/getting-started/deploying-the-infrastructure)). **topf** generates, applies and bootstraps Talos ([Install Talos](/kubernetes/getting-started/install-talos)) |
| `just` modules (`bootstrap::full`, `tf::apply`, …) | `just` modules `tf`, `talos`, `bootstrap`, plus `just full` ([justfile](/kubernetes/getting-started/bootstrap#the-justfile)) |
| SOPS + age for Talos/Terraform files, **Sealed Secrets** for in-cluster secrets | SOPS for everything. Flux decrypts natively, the YubiKey GPG key is for humans ([SOPS](/kubernetes/sops)) |
| `helm install argo-cd`, then `kubectl apply root.yaml` | helmfile installs `flux-operator` + `flux-instance`. `FluxInstance.spec.sync` creates the root sync, so there's nothing to apply by hand |
| App-of-apps `root.yaml` → `bootstrap/` | `FluxInstance.spec.sync` → `kubernetes/apps` directly. Defaults are injected by the instance's kustomize patches ([Flux](/kubernetes/flux/intro#the-fluxinstance)) |
| `ApplicationSet` with a git directory generator over `apps/*` | One explicit `ks.yaml` per app, listed in the namespace `kustomization.yaml` |
| Sync waves (`-100`, `-2`, `-1`, `0`, `2`) | `dependsOn` between Kustomizations, plus `healthChecks` / `healthCheckExprs` |
| `syncPolicy.automated.prune` | `spec.prune: true` |
| `selfHeal: true` | Flux always reverts drift on its `interval`. Suspend with `flux suspend kustomization …` to experiment |
| `CreateNamespace=true` | An explicit `namespace.yaml` per namespace. `targetNamespace` doesn't create it ([Kustomization API](https://fluxcd.io/flux/components/kustomize/kustomizations/)) |
| `ServerSideApply=true` | kustomize-controller already applies server-side |
| `SkipDryRunOnMissingResource=true` | `dependsOn` on the Kustomization that installs the CRD, or install CRDs at bootstrap like cluster-template's `crds.yaml` |
| `resources-finalizer.argocd.argoproj.io` | `prune: true` + `deletionPolicy` (`WaitForTermination` via the root defaults) |
| Helm source in an `Application` (`repoURL`, `targetRevision`, inline values) | `OCIRepository` + `HelmRelease.spec.chartRef` + `values` |
| Repo credentials secret labelled `argocd.argoproj.io/secret-type: repository` | `FluxInstance.spec.sync.pullSecret` (SSH `identity` / `known_hosts`) |

I haven't verified that kustomize-controller applies server-side by default against a specific doc page. It is how Flux v2 has worked since its early releases, but treat that row as unverified.

## 1. Planning my Kubernetes homelab

[Post](https://jonashietala.se/blog/2026/05/05/planning_my_kubernetes_homelab). Jonas sets three goals: a declarative, reproducible setup bootstrapped from one Git repo; working backups; and the blog posts as documentation. He picks Talos on Proxmox (provisioned with Terraform), Cilium (replacing kube-proxy, MetalLB and Traefik, with Gateway API instead of Ingress), ArgoCD, Renovate, CloudNativePG, Longhorn with VolSync/Restic, Sanoid/Syncoid/Kopia to Backblaze via Garage, and Authentik for SSO. He calls FluxCD possibly the "simpler" choice for personal use, but uses ArgoCD because he uses it at work.

**Flux translation:** the same goals. My stack differs in a few places:

- **Flux** instead of ArgoCD.
- **External Postgres** instead of CloudNativePG, for now.
- **topf** instead of the Terraform Talos provider for the Talos side.

Everything else matches his choices: Talos on Proxmox via Terraform, Cilium for CNI/LB/Gateway API, Longhorn ([Storage: Longhorn](/kubernetes/storage-longhorn)), Authentik and `just`.

## 2. Talos Linux on Proxmox with Terraform

[Post](https://jonashietala.se/blog/2026/05/22/talos_linux_on_proxmox_with_terraform). The cluster:

- **Provisioning:** Terraform with `bpg/proxmox` 0.95.0 and `siderolabs/talos` 0.10.1, building three control-plane VMs from an Image Factory `nocloud` image for Talos 1.12.6 with `qemu-guest-agent`.
- **Machine config patches:** CNI `none`, kube-proxy disabled, scheduling on control planes, and a VIP on `eth0`.
- **Cilium:** 1.19.2, installed with Helm after applying the Gateway API v1.2.1 CRDs. Values include `kubeProxyReplacement`, L2 announcements, external IPs, Gateway API, and `securityContext.privileged`.
- **Load balancing:** a `CiliumLoadBalancerIPPool` and a `CiliumL2AnnouncementPolicy`.
- **Gotchas:** a Proxmox 8 disk-resize bug, fish as the login shell breaking the provider, and `talosctl health` stalling until a CNI exists.

**Flux translation:** this step has no GitOps tool in it. The differences:

- **Terraform does less.** It uses only `bpg/proxmox` (now v0.123.1) to create the VMs, with the same `nocloud` image and cloud-init static IPs (`10.0.11.1–3`). topf replaces the `siderolabs/talos` provider for secrets, config, apply and bootstrap. The Talos image schematic adds `iscsi-tools` and `util-linux-tools` for Longhorn, which Jonas also mentions.
- **Talos 1.14 config documents.** Use `KubeFlannelCNIConfig` (`$patch: delete`), `KubeProxyConfig` (`enabled: false`), `KubeNodeConfig` and `Layer2VIPConfig` instead of the 1.12-era `cluster.*` fields ([What's new in 1.14](https://docs.siderolabs.com/talos/v1.14/getting-started/what's-new-in-talos.md), [Talos Cilium guide](https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium.md)).
- **KubePrism.** Point `k8sServiceHost` at KubePrism (`localhost:7445`) instead of the VIP.
- **Newer versions.** Cilium 1.20 needs Gateway API v1.6.3 CRDs ([Cilium docs](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api/)).
- **Bootstrap path.** Cilium is installed by helmfile from values that Flux later owns ([Bootstrap](/kubernetes/getting-started/bootstrap)).

See [Deploying the infrastructure](/kubernetes/getting-started/deploying-the-infrastructure) and [Install Talos](/kubernetes/getting-started/install-talos).

## 3. Just: command runner & documentation

[Post](https://jonashietala.se/blog/2026/05/28/just_command_runner_documentation). Jonas organises a top-level `justfile` into modules under `just/`: `bootstrap`, `tf`, `secrets`, `argocd`, and others.

- `bootstrap::full` chains `cluster` → `cilium` → restore the Sealed Secrets key → `sealed_secrets` → `argocd`.
- `tf::apply` re-encrypts Terraform state in an `EXIT` trap.
- `wait_for_api` waits for nodes to register before Cilium is installed.

**Flux translation:** the same tool and the same idea, with fewer steps, because there's no Sealed Secrets controller and no key to restore. `just full` runs:

1. `tf::apply`, with the state decrypted and re-encrypted in a trap like his.
2. `talos::create` (topf secrets, apply `--auto-bootstrap`, talosconfig/kubeconfig).
3. `bootstrap::apps`: wait for nodes, `sops decrypt` the bootstrap secrets with the YubiKey, Gateway API CRDs, `helmfile sync`.

The full justfile is on [Bootstrap](/kubernetes/getting-started/bootstrap#the-justfile). The steps follow cluster-template's `mise` tasks ([bootstrap/mise.toml](https://github.com/onedr0p/cluster-template/blob/main/template/config/bootstrap/mise.toml)).

## 4. SOPS + Age and Sealed Secrets

[Post](https://jonashietala.se/blog/2026/05/31/sops_age_and_sealed_secrets). Jonas uses SOPS + age with per-path `.sops.yaml` rules for the files that live outside the cluster: `talosconfig` and `kubeconfig` (only `ca|crt|key` encrypted), `secrets.auto.tfvars`, Terraform state, and the Sealed Secrets private key. In-cluster secrets use Sealed Secrets (`kubeseal --cert`), because it produces native objects. He backs up the Sealed Secrets key with SOPS so that a rebuilt cluster can still decrypt the existing SealedSecrets.

**Flux translation:** Sealed Secrets isn't needed. Flux's kustomize-controller decrypts SOPS files at apply time ([Flux SOPS guide](https://fluxcd.io/flux/guides/mozilla-sops/)), so Kubernetes `Secret`s are committed as `*.sops.yaml`. Jonas's two keys (age master key + Sealed Secrets key) become:

- one GPG key on two YubiKeys, for me;
- one age key for Flux, stored in the repo encrypted to that GPG key only.

The "secrets are per-namespace" annoyance he mentions goes away for the decryption key itself, because the controller-level `--sops-age-secret` covers it. See [SOPS](/kubernetes/sops).

## 5. GitOps with ArgoCD

[Post](https://jonashietala.se/blog/2026/07/23/gitops_with_argocd). Jonas installs the Argo CD chart 10.1.4 with Helm and manages two secrets as SealedSecrets: the repo credentials (with the `argocd.argoproj.io/secret-type: repository` label) and `argocd-secret` (with a fixed `server.secretkey`). The repo has three levels:

1. `root.yaml`, applied once by hand.
2. `bootstrap/`, holding Applications for the Gateway API CRDs (wave `-2`), Cilium and Sealed Secrets (`-1`), and Argo CD itself.
3. An `ApplicationSet` that generates one Application per directory under `apps/`.

The sync options are `prune`, `selfHeal`, `ServerSideApply`, `SkipDryRunOnMissingResource` and `CreateNamespace`. Renovate, with Argo/Kubernetes file patterns, is the first app. His main complaint: the Cilium Helm values are duplicated between the bootstrap `helm install` and the Application.

**Flux translation:** this is the post with the most changes:

| ArgoCD step | Flux step |
| --- | --- |
| `helm install argo-cd`, then apply the repo secret and `argocd-secret` | helmfile installs `flux-operator` and `flux-instance`. The only secrets are `sops-age` and the SSH pull secret ([Bootstrap](/kubernetes/getting-started/bootstrap)) |
| `kubectl apply -f root.yaml` | Not needed: `FluxInstance.spec.sync` creates the `flux-system` GitRepository + Kustomization ([FluxInstance docs](https://fluxoperator.dev/docs/crd/fluxinstance/)) |
| `bootstrap/argocd.yaml`: Argo CD manages itself | `kubernetes/apps/flux-system/{flux-operator,flux-instance}`: Flux manages the operator and its own instance |
| Gateway API CRDs Application at wave `-2` | A `GitRepository` on `kubernetes-sigs/gateway-api` (tag `v1.6.3`) + a Kustomization on the experimental CRDs, which `ExternalAuth` needs. The `gateway` Kustomization `dependsOn` it |
| Cilium Application at wave `-1` with duplicated values | `kubernetes/apps/kube-system/cilium/` HelmRelease. helmfile reads the same file, so there is no duplication ([cluster-template helmfile templates](https://github.com/onedr0p/cluster-template/tree/main/template/config/bootstrap/helmfile/templates)) |
| `ApplicationSet` over `apps/*` | A `ks.yaml` per app, explicitly listed. This is more typing, but each app gets its own `dependsOn`, health checks and timeout |
| Fixed `server.secretkey` to stop logouts | Not applicable. Flux has no built-in UI session to keep alive |
| Renovate (`argocd` + `kubernetes` managers) | Renovate's `flux` manager. The existing `renovate.json` already configures it. Whether Renovate should also run in-cluster, as Jonas runs it, is up to me |

## 6. Domains, certificates, and DNS

[Post](https://jonashietala.se/blog/2026/08/06/domains_certificates_and_dns). The pieces:

- **Gateway:** one Cilium `Gateway` (`gatewayClassName: cilium`) in `kube-system`, with a fixed LB IP via `io.cilium/lb-ipam-ips` and HTTP/HTTPS listeners using a wildcard certificate.
- **Certificates:** cert-manager v1.21.0 with a Namecheap DNS-01 webhook. Separate staging and production ClusterIssuers issue a `*.hietala.xyz` certificate.
- **DNS:** ExternalDNS 1.21.1 with the OPNsense Unbound webhook, creating per-host overrides from `HTTPRoute`s.
- **Routes:** one `HTTPRoute` per app.
- **Gotchas:** an Argo CD 3.3.5 diff bug on HTTPRoute defaults, and ordering by sync waves (cert-manager `-1`, issuer `0`, certificate `2`).

**Flux translation:**

- **Same Gateway design.** One Cilium `Gateway` in `kube-system` on `10.0.12.1`, HTTP/HTTPS listeners, a wildcard certificate, and an `HTTPRoute` per app ([Bootstrap: Cilium networking](/kubernetes/getting-started/bootstrap#cilium-networking)).
- **The IP is pinned with `spec.addresses`.** Jonas uses the `io.cilium/lb-ipam-ips` annotation, which Cilium's docs say will be deprecated in favour of `spec.addresses` ([Gateway addresses](https://github.com/cilium/cilium/blob/v1.20.5/Documentation/network/servicemesh/gateway-api/addresses.rst)).
- **Ordering.** Sync waves become `dependsOn`: `cluster-issuer` → `cert-manager`, and `gateway` → `cluster-issuer` + `gateway-api-crds` ([migration order](/kubernetes/migration#suggested-order)).
- **DNS-01 provider.** Mine is **Cloudflare**, which cert-manager supports natively, so no webhook is needed. The existing `ClusterIssuer` carries over.
- **No HTTPRoute diff bug.** That Argo CD bug has no Flux counterpart, because kustomize-controller applies server-side and doesn't diff against defaulted fields the same way. Treat this as **unverified**.
- **ExternalDNS** (his OPNsense webhook) vs one wildcard DNS record pointing at `10.0.12.1` is an [open question](/kubernetes/migration#open-questions).
- **Authentik forward auth** is in the planned "SSO with Authentik" post. Until it's out, see [forward auth with Cilium Gateway](/kubernetes/migration#authentik-forward-auth-with-cilium-gateway).
