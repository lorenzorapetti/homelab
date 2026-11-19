---
sidebar_position: 6
---

# Migrating from k3s

The Talos cluster starts as a [bare skeleton](/kubernetes/getting-started/bootstrap): Talos, Cilium, the Flux Operator with a `FluxInstance` syncing an empty `kubernetes/apps/`, and the `sops-age` Secret. The k3s cluster is gone, so nothing runs in parallel. Apps are added **by hand, one app per commit/PR**, in the order below. Each step is small enough to review, reconcile and check before the next one. Nothing here is meant to be dropped in all at once.

The k3s manifests are kept for reference in `kubernetes_old/`. Nothing reconciles from there, and its SOPS secrets are still encrypted to the age key only.

## Adding one app

1. **Namespace** (for the first app in it): create `kubernetes/apps/<ns>/kustomization.yaml` (with `components: [../../components/sops]`) and `namespace.yaml`, then add `./<ns>` to `kubernetes/apps/kustomization.yaml` ([Repository Architecture](/kubernetes/flux/repository-architecture#a-namespace)). Skip `namespace.yaml` for a namespace that Kubernetes or the bootstrap creates, such as `kube-system` ([why](/kubernetes/flux/repository-architecture#kube-system-no-namespaceyaml)).
2. **`ks.yaml`**: copy it from the k3s repo, then:
   - add `patches: []` (required by the FluxInstance's injected patch) and `postBuild.substituteFrom: cluster-secrets` if needed;
   - keep only the `dependsOn` entries for apps that already exist in the new cluster;
   - replace `traefik`/`ceph` dependencies with `gateway`/`longhorn`.
3. **`app/`**:
   - Use `ocirepository.yaml` + `chartRef` where the chart is published as OCI, otherwise a `HelmRepository`.
   - Drop the inline `install/upgrade.crds` settings.
   - Replace Traefik `IngressRoute` + per-app `Certificate` with an `HTTPRoute` on the shared Gateway ([example](/kubernetes/flux/repository-architecture#routing-an-app)).
   - Change `storageClassName: ceph-rbd`/`cephfs` to Longhorn's class.
   - Rename secrets to `*.sops.yaml` and run `sops updatekeys` ([SOPS](/kubernetes/sops#re-encrypting-existing-files)).
4. **Data**: if the app had a PVC, carry out its copy/restore plan ([Longhorn: data from the old cluster](/kubernetes/storage-longhorn#data-from-the-old-cluster)).
5. **Commit, push, `just bootstrap::reconcile`**, then `flux get kustomizations -A`. The app's Kustomization must go `Ready` on its health checks.

## Suggested order

The dependencies come from the k3s `ks.yaml` files, with Traefik replaced by the Cilium Gateway and Ceph by Longhorn.

| # | App(s) | Namespace | Depends on | Notes |
| --- | --- | --- | --- | --- |
| 0 | *skeleton* | — | — | [Bootstrap](/kubernetes/getting-started/bootstrap) |
| 1 | `cilium` | `kube-system` | — | **Done 2026-11-18.** Adopt the helmfile release (one upgrade, all Cilium pods roll once: [what the takeover does](/kubernetes/getting-started/bootstrap#what-the-takeover-does-cilium-2026-11-18)). Add `networks.yaml`: the LB pool `10.0.12.1–254` and the L2 policy ([network map](/kubernetes/intro#network-map)). Adds the `sops` component with `cluster-secrets` ([shape](/kubernetes/flux/repository-architecture#cluster-secrets)) |
| 2 | `flux-operator`, `flux-instance` | `flux-system` | `flux-instance` → `flux-operator` | **Done 2026-11-19.** Adopt the helmfile releases (one upgrade each, and only the operator pod rolled: [what the takeover does](/kubernetes/getting-started/bootstrap#what-the-takeover-does-flux-2026-11-19)). `prune: disabled` on the whole `flux-system` chain so Flux can't uninstall itself ([why](/kubernetes/flux/intro#flux-must-never-uninstall-itself)). The helmfile now [reads chart, version and values from the manifests](/kubernetes/getting-started/bootstrap#one-source-of-truth-for-values), and `bootstrap/helmfile/values/` is gone |
| 3 | `gateway-api-crds` | `kube-system` | — | A `GitRepository` on `kubernetes-sigs/gateway-api` at `v1.6.3` plus a Kustomization on `config/crd/experimental` (for `ExternalAuth`), both in `ks.yaml` ([the CRDs as a Flux app](/kubernetes/getting-started/bootstrap#the-crds-as-a-flux-app)). `prune: disabled` on every object, because the injected `deletionPolicy` ignores `prune: false`. `just bootstrap::crds` reads the tag from it |
| 4 | **`longhorn`** | `longhorn-system` | — | **Done 2026-11-19.** Early, so every stateful app can depend on it. Privileged namespace, `defaultDataPath: /var/mnt/longhorn`, chart `1.13.0` from a `HelmRepository` (no OCI chart). `longhorn` is the default StorageClass with 2 replicas. No kubelet extra mount needed ([as built](/kubernetes/storage-longhorn#as-built-2026-11-19)) |
| 5 | `cert-manager`, then `cluster-issuer` | `cert-manager` | `cluster-issuer` → `cert-manager` | **Done 2026-11-19.** The Cloudflare DNS-01 issuer `cloudflare-cluster-issuer` carries over, and `cloudflare-cluster-issuer-staging` is new, for tests. The chart moves to OCI and from v1.19.1 to v1.21.3, which cert-manager only tests up to Kubernetes 1.36 ([why it's fine for now](/kubernetes/flux/repository-architecture#cert-managerappocirepositoryyaml)). Health-checked on the `HelmRelease` only, with no separate `Deployment` check. A staging `Certificate` went Ready through DNS-01 |
| 6 | `gateway` | `kube-system` | `cilium`, `gateway-api-crds`, `cluster-issuer` | **Done 2026-11-19.** The shared `Gateway` `main` on `10.0.12.1`, plus a production wildcard `Certificate` (apex + `*.<domain>`, Secret `${SECRET_DOMAIN/./-}-tls`). HTTP is a `301` to HTTPS for every host, and apps attach only to `sectionName: https`. Health-checked on the Certificate and, through `healthCheckExprs`, on the Gateway's `Programmed` condition ([as built](/kubernetes/getting-started/bootstrap#the-shared-gateway)). Tested end to end with a throwaway app and `curl --resolve`, with no DNS record ([open question 13](#open-questions)) |
| 7 | `kube-prometheus-stack` | `observability` | `gateway`, `longhorn` | Could move the `ServiceMonitor` CRDs earlier, as cluster-template does with `prometheus-operator-crds` ([crds.yaml](https://github.com/onedr0p/cluster-template/blob/main/template/config/bootstrap/helmfile/crds.yaml.j2)). That would remove `rabbitmq`'s dependency on it |
| 8 | `authentik` | `auth` | `gateway` | External Postgres/Redis as before. See [forward auth](#authentik-forward-auth-with-cilium-gateway) |
| 9 | `glance` | `glance` | `gateway`, `authentik` | Stateless, so it's a good first end-to-end test of Gateway + auth |
| 10 | `gitea` | `git` | `gateway` | External DB/cache. Has a PVC, so it also needs `longhorn` and a data plan. SSH (was Traefik entrypoint `gitea-ssh`, port 55522) needs a new home: see [open questions](#open-questions) |
| 11 | `actual` | `actual` | `gateway`, `longhorn`, `authentik` | Plain manifests. PVC: needs a data plan |
| 12 | `pgadmin` | `db` | `gateway`, `longhorn` | PVC |
| 13 | `netbox` | `netbox` | `gateway`, `longhorn` | PVC |
| 14 | `portainer` | `portainer` | `gateway`, `longhorn` | PVC. Check whether it's still wanted |
| 15 | `mattermost-operator`, then `mattermost` | `mattermost` | `mattermost` → `mattermost-operator`, `gateway` | External DB and filestore secrets |
| 16 | `rabbitmq` | `rabbitmq` | `gateway`, `longhorn`, `kube-prometheus-stack` | Already an `OCIRepository`. PVC |

How the order is built:

- **1–6 are the platform.** Networking, Flux, storage, certificates and the Gateway come first, because every app needs a route, and most need a certificate or a volume.
- **Longhorn comes early (4).** Nothing stateful can start without it, and it is the one component with Talos-side prerequisites (extensions, user volume) that are worth testing on an empty cluster.
- **Stateless or externally-backed apps go before PVC-backed ones**, so the platform is proven before any data moves.

## Data

- **External state stays put.** Postgres (`db-1.cluster.lorenzolab.com`) and Redis (`redis-1…`) live outside Kubernetes. Apps that only use them (authentik, gitea's DB, netbox's DB, mattermost) point at the same endpoints.
- **PVC data was on Ceph and needs a manual plan.** The old PVCs lived on the external Ceph cluster (`ceph-rbd`, `cephfs`), and Longhorn starts empty. For each PVC-backed app, choose copy, restore or start fresh, and do it **before the Ceph cluster is torn down** ([Longhorn: data from the old cluster](/kubernetes/storage-longhorn#data-from-the-old-cluster)).
- **Backups.** Jonas's series puts backups (VolSync/Restic, Kopia) in the planned "Backups" post, which isn't published yet ([series index](https://www.jonashietala.se/series/kube-homelab/)). Until a backup story exists, take a manual copy before each cut-over. While all VMs share one host, Longhorn replicas aren't a backup.

## Authentik forward auth with Cilium Gateway

In the k3s cluster, apps without their own login sat behind a Traefik `forwardAuth` middleware pointing at Authentik. Cilium has no Traefik-style middleware, but there are three ways to get the same result.

**1. Gateway API `ExternalAuth` filter (Cilium ≥ 1.20).** The Cilium 1.20 changelog says: "Cilium now supports the `ExternalAuth` filter type in HTTPRoutes (GEP-1494). Routes can delegate authorization decisions to an external service using either gRPC (Envoy ext_authz protocol) or HTTP" ([CHANGELOG v1.20.5](https://github.com/cilium/cilium/blob/v1.20.5/CHANGELOG.md)). Cilium ships a working example ([external-authz example](https://github.com/cilium/cilium/tree/v1.20.5/examples/kubernetes/gateway/external-authz)). GEP-1494 has status *Experimental* ([GEP](https://gateway-api.sigs.k8s.io/geps/gep-1494/)), which is why the bootstrap installs the experimental-channel CRDs.

On the Authentik side, the embedded outpost speaks Envoy's ext_authz HTTP protocol at path `/outpost.goauthentik.io/auth/envoy` on port `9000`. It forwards `cookie` to the check and returns `x-authentik-*` headers ([Authentik: Envoy/Istio](https://docs.goauthentik.io/add-secure-apps/providers/proxy/server_envoy/)). Put together:

```yaml
rules:
  - filters:
      - type: ExternalAuth
        externalAuth:
          protocol: HTTP
          backendRef:
            name: ak-outpost-authentik-embedded-outpost
            namespace: auth
            port: 9000
          http:
            path: /outpost.goauthentik.io/auth/envoy
            allowedHeaders: [cookie]
            allowedResponseHeaders: [set-cookie, x-authentik-username, x-authentik-groups, x-authentik-email]
    backendRefs:
      - name: glance
        port: 8080
```

**Unverified, so treat it as an experiment:**

- The filter shape comes from Cilium's example. The `allowedHeaders` key is from the GEP's Go struct, and the outpost Service name and namespace from Authentik's Istio example.
- I haven't tested this exact combination.
- A cross-namespace `backendRef` normally needs a `ReferenceGrant` in `auth`.
- Authentik's login redirect/callback flow may also need `/outpost.goauthentik.io/` on each app host routed to the outpost. The Envoy page doesn't say.
- Cilium's own NGINX-migration guide still lists `auth-url` → `ExternalAuth` as "Not yet supported" ([doc](https://github.com/cilium/cilium/blob/v1.20.5/Documentation/network/servicemesh/ingress-to-gateway/nginx-annotations-migration.rst)). That contradicts the changelog and is probably stale.

**2. Authentik proxy provider in "Proxy" mode.** "The authentik outpost should proxy traffic to one upstream application" ([Authentik proxy provider](https://docs.goauthentik.io/add-secure-apps/providers/proxy/)). The app's `HTTPRoute` sends traffic to the outpost, and the outpost forwards authenticated requests to the app. This uses only standard Gateway API features, at the cost of an extra hop and one provider per app.

**3. Native OIDC in the app.** Apps that support it (Grafana already has an OAuth secret, and Actual an OpenID secret, in the k3s repo) log in against Authentik directly and need no gateway auth at all.

**Plan:** use (3) wherever the app supports it, and (1) for the rest, starting with glance. Fall back to (2) if (1) doesn't work with Authentik.

## What changes and what carries over

| Area | k3s repo | Talos rebuild |
| --- | --- | --- |
| Machines | k3s VMs installed with `k3sup` | Terraform (`bpg/proxmox`) VMs, Talos v1.14 configured by topf ([Deploying the infrastructure](/kubernetes/getting-started/deploying-the-infrastructure), [Install Talos](/kubernetes/getting-started/install-talos)) |
| CNI / LB / ingress | k3s defaults + bundled Traefik (`HelmChartConfig`) | Cilium: kube-proxy replacement, LB IPAM + L2 on `10.0.12.0/24`, Gateway API on `10.0.12.1`. No Traefik |
| Routes and TLS | Traefik `IngressRoute`, one `Certificate` per app | `HTTPRoute` per app, wildcard cert on the Gateway |
| Storage | External Ceph via raw ceph-csi manifests | Longhorn in-cluster ([Storage: Longhorn](/kubernetes/storage-longhorn)) |
| Flux install | `flux bootstrap`, `gotk-components.yaml` (v2.7.5) | Flux Operator + `FluxInstance`, Flux v2.10 ([Flux](/kubernetes/flux/intro)) |
| Root sync | `kubernetes/cluster/{flux-system/, ks.yaml}` | FluxInstance syncs `kubernetes/apps` directly. Defaults are injected by instance patches |
| SOPS | One rule for every `*.yaml`, age only, key copied into every namespace | `*.sops.*` only, YubiKey GPG + age, controller-level key ([SOPS](/kubernetes/sops)) |
| Chart sources | `HelmRepository` + `chart.spec` (rabbitmq already OCI) | `OCIRepository` + `chartRef` where available |
| Task runner | — | `just` modules |

**Carried over unchanged:**

- **App layout and conventions**: the per-app `ks.yaml` + `app/` layout, `&app` anchors, `commonMetadata`, `retryInterval`, timeouts, `healthChecks`/`healthCheckExprs`, cross-namespace `dependsOn`, and the `yaml-language-server` headers.
- **External services and identities**: the age recipient, the Cloudflare DNS-01 `ClusterIssuer`, the domains, the external Postgres/Redis endpoints, the GitHub repo URL and the deploy key.
- **`renovate.json`.** Its `flux`, `kubernetes` and `helm-values` managers already match `kubernetes/**`. **To check:** add `bootstrap/helmfile/**`, `talos/topf.yaml` and `infrastructure/` coverage. cluster-template annotates `topf.yaml` versions with `# renovate:` comments ([topf.yaml](https://github.com/onedr0p/cluster-template/blob/main/template/config/talos/topf.yaml.j2)) and uses `home-operations/renovate-presets` ([`.renovaterc.json5`](https://github.com/onedr0p/cluster-template/blob/main/.renovaterc.json5)).

**Dropped:**

- `gotk-*.yaml`, the root `ks.yaml` and `components/common/sops`
- Traefik and every `IngressRoute`/middleware
- `kubernetes/apps/ceph` and the Ceph storage classes
- the k3s doc pages

## Open questions

1. **Gitea SSH.** It was Traefik entrypoint `gitea-ssh` on port 55522. Options: a dedicated `LoadBalancer` Service with its own pool IP (e.g. `10.0.12.2` via `lbipam.cilium.io/ips`), or a `TCPRoute` on the Gateway. Cilium treats TCPRoute as optional and needs its experimental CRD ([Cilium Gateway API docs](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api/)).
2. **Authentik forward auth.** Does the `ExternalAuth` + embedded outpost combination actually work, including the login redirect? If not, use proxy mode for those apps ([above](#authentik-forward-auth-with-cilium-gateway)).
3. **VM sizing while on one host.** 2 cores, 4.5GB RAM, 50GB system disk and 200GB Longhorn disk per VM is tight. Do I run fewer apps until hosts `.2`/`.3` exist, or start with a single Talos VM? ([sizing](/kubernetes/getting-started/deploying-the-infrastructure#sizing)) Data point: idle Longhorn takes ~180 MB and ~30m CPU per node, and leaves ~2.1 GB available per node ([resource use](/kubernetes/storage-longhorn#as-built-2026-11-19)).
4. ~~**Longhorn on Talos 1.14.** Is the kubelet extra mount for `/var/mnt/longhorn` needed, and does `!system_disk` select only the data disk?~~ **Settled 2026-11-19: no extra mount.** The selector picks only `sdb` (215 GB, `xfs` at `/var/mnt/longhorn`), and volumes attach on any node ([as built](/kubernetes/storage-longhorn#as-built-2026-11-19)).
5. **topf and Talos 1.14.** topf officially lists Talos v1.13. Is that acceptable, or should I pin Talos to 1.13 until topf lists 1.14?
6. **UEFI vs SeaBIOS** for the `nocloud` raw image in Terraform, and the image's real compression (`.raw.xz` vs `zst`).
7. **CoreDNS.** Keep it Talos-managed, or disable it and manage the chart with Flux like cluster-template?
8. ~~**Flux version pin.** `2.10.x` (deliberate minor upgrades) or the chart default `2.x`?~~ **Settled 2026-11-19: `2.10.x`.** A Flux minor upgrade stays a deliberate commit ([The FluxInstance](/kubernetes/flux/intro#the-fluxinstance)).
9. **Pod Security.** Keep Talos's `baseline` default and label privileged namespaces, or delete the admission config like cluster-template?
10. **OCI charts.** Which of authentik, gitea, pgadmin4, netbox, kube-prometheus-stack, portainer and mattermost-operator publish OCI charts? (Longhorn doesn't, checked 2026-11-19.)
11. **Flux webhook receiver.** Add a GitHub → Flux `Receiver` through the Gateway (and revisit `networkPolicy`) instead of polling every minute?
12. **Flux alerts.** Flux 2.10 notification `Alert`/`Provider` are `v1` now. Where should alerts go?
13. **ExternalDNS.** Jonas automates DNS records from `HTTPRoute`s ([post 6](https://jonashietala.se/blog/2026/08/06/domains_certificates_and_dns)). Do I want that, or one wildcard record pointing at `10.0.12.1`? The Gateway was tested without either, using `curl --resolve` (2026-11-19). glance (step 9) is the first app that needs a real record.
