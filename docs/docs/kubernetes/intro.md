---
sidebar_position: 1
sidebar_label: Introduction
---

# Kubernetes

This section documents my homelab Kubernetes cluster. It is being rebuilt from scratch on:

- **[Talos Linux](https://www.talos.dev/)** as OS and Kubernetes distribution, configured with **[topf](https://postfinance.github.io/topf/main/)**, on Proxmox VMs created with **Terraform**.
- **[Cilium](https://cilium.io/)** for everything network: CNI, kube-proxy replacement, LoadBalancer IPs (LB IPAM + L2 announcements) and ingress through **Gateway API**. There is no Traefik and no separate gateway.
- **[Flux](https://fluxcd.io/)** for GitOps, installed and upgraded by the **[Flux Operator](https://fluxoperator.dev/)** through a `FluxInstance`.
- **[Longhorn](https://longhorn.io/)** for persistent volumes, inside the cluster.
- **[SOPS](https://github.com/getsops/sops)** for secrets: my YubiKeys for humans and an age key for Flux.
- **[just](https://just.systems/)** to wrap the commands.

The repository uses the "home-ops" layout of [onedr0p/cluster-template](https://github.com/onedr0p/cluster-template) ([Repository Architecture](/kubernetes/flux/repository-architecture)). The narrative backbone is Jonas Hietala's [Modern Kubernetes homelab](https://www.jonashietala.se/series/kube-homelab/) series, followed with Flux instead of ArgoCD ([Jonas's series in Flux](/kubernetes/jonas-series-flux)).

The old k3s cluster is gone. The new cluster starts as a [bare skeleton](/kubernetes/getting-started/bootstrap), and apps are added one at a time, following [Migrating from k3s](/kubernetes/migration).

## Hardware

I have three HP EliteDesk 800 G4 mini PCs, each equipped with an Intel i5-8500T CPU, 16GB of RAM, and a 1TB SSD. They run Proxmox. Right now only the first host (`10.0.10.1`) is in use, and it runs all three Talos VMs (see [Deploying the infrastructure](/kubernetes/getting-started/deploying-the-infrastructure#nodes)).

## Network map

The LAN is one flat `10.0.0.0/16` behind the router at `10.0.0.1`. DHCP only hands out `10.0.0.x`, so everything outside `10.0.0.0/24` is free for static use.

| Range / address | What | Notes |
| --- | --- | --- |
| `10.0.0.1` | Router / default gateway | |
| `10.0.0.0/24` | DHCP clients | Not used for anything static |
| `10.0.1.30` | LAN DNS server | First nameserver on the Talos nodes (`ResolverConfig`) |
| `10.0.10.0/24` | Proxmox hosts | `10.0.10.1` now; `.2` and `.3` later |
| `10.0.11.0/24` | Talos VMs | Static, set by Terraform cloud-init. Netmask `/16`, gateway `10.0.0.1` |
| `10.0.11.1`–`10.0.11.3` | `talos-1`…`talos-3` | Control plane + workloads |
| `10.0.11.10` | Kubernetes API VIP | Talos `Layer2VIPConfig` on the control-plane nodes ([Install Talos](/kubernetes/getting-started/install-talos#control-plane-patches)) |
| `10.0.12.0/24` | Cilium LB IPAM pool, `10.0.12.1`–`10.0.12.254` | Announced with Cilium L2 announcements (ARP). Everything is on one flat L2 segment, so no BGP is needed ([Bootstrap: Cilium](/kubernetes/getting-started/bootstrap#cilium-networking)) |
| `10.0.12.1` | Shared Cilium `Gateway` | HTTP/HTTPS entry point for all apps |
| `10.244.0.0/16` | Pod CIDR | **Cluster-internal only.** Doesn't overlap the LAN |
| `10.96.0.0/12` | Service CIDR | **Cluster-internal only** (`10.96.0.0`–`10.111.255.255`). Doesn't overlap the LAN |

The pod and service CIDRs are the values in Talos's `KubeNetworkConfig` reference example ([reference](https://docs.siderolabs.com/talos/v1.14/reference/configuration/kubernetes/kubenetworkconfig.md)). That page doesn't state defaults, so I set them explicitly in the Talos patches to be safe.

## Versions

I checked these against upstream release pages on 2026-11-18. Renovate keeps the pinned versions current after that.

| Component | Version | Source |
| --- | --- | --- |
| Talos Linux | v1.14.5 pinned (= devenv `talosctl`; v1.14.6 is out) | [siderolabs/talos releases](https://github.com/siderolabs/talos/releases) |
| Kubernetes | v1.37.2 (cluster-template pins the same) | [cluster-template `topf.yaml`](https://github.com/onedr0p/cluster-template/blob/main/template/config/talos/topf.yaml.j2) |
| topf | v0.6.2 | [postfinance/topf releases](https://github.com/postfinance/topf/releases) |
| Terraform provider `bpg/proxmox` | v0.123.1 | [releases](https://github.com/bpg/terraform-provider-proxmox/releases) |
| Flux | v2.10.0 (supports Kubernetes 1.35–1.37) | [flux2 v2.10.0 release notes](https://github.com/fluxcd/flux2/releases/tag/v2.10.0) |
| Flux Operator / `flux-instance` chart | v0.62.1 | [flux-operator releases](https://github.com/controlplaneio-fluxcd/flux-operator/releases) |
| Cilium | 1.20.5 | [cilium releases](https://github.com/cilium/cilium/releases) |
| Gateway API CRDs | v1.6.3 (the version Cilium 1.20 documents) | [Cilium Gateway API docs](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api/) |
| Longhorn | v1.13.0 | [longhorn releases](https://github.com/longhorn/longhorn/releases) |
| helmfile | v1.8.4 | [helmfile releases](https://github.com/helmfile/helmfile/releases) |
| just | 1.59.0 | [just releases](https://github.com/casey/just/releases) |
| SOPS / age | v3.13.3 / v1.3.2 | [sops releases](https://github.com/getsops/sops/releases), [age releases](https://github.com/FiloSottile/age/releases) |
