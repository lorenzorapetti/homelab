---
sidebar_position: 6
---

# Adding apps

The cluster starts as a [bare skeleton](/kubernetes/getting-started/bootstrap): Talos, Cilium, the Flux Operator with a `FluxInstance` syncing an empty `kubernetes/apps/`, and the `sops-age` Secret. Apps are added **by hand, one app per commit/PR**. Each step is small enough to review, reconcile and check before the next one.

## Adding one app

1. **Namespace** (for the first app in it): create `kubernetes/apps/<ns>/kustomization.yaml` (with `components: [../../components/sops]`) and `namespace.yaml`, then add `./<ns>` to `kubernetes/apps/kustomization.yaml` ([Repository Architecture](/kubernetes/flux/repository-architecture#a-namespace)). Skip `namespace.yaml` for a namespace that Kubernetes or the bootstrap creates, such as `kube-system` ([why](/kubernetes/flux/repository-architecture#kube-system-no-namespaceyaml)).
2. **`ks.yaml`**:
   - add `patches: []` (required by the FluxInstance's injected patch) and `postBuild.substituteFrom: cluster-secrets` if needed;
   - `dependsOn` what the app needs, usually `gateway`, `longhorn` and `authentik`.
3. **`app/`**:
   - Use `ocirepository.yaml` + `chartRef` where the chart is published as OCI, otherwise a `HelmRepository`.
   - Expose it with an `HTTPRoute` on the shared Gateway ([example](/kubernetes/flux/repository-architecture#routing-an-app)).
   - Name secrets `*.sops.yaml` ([SOPS](/kubernetes/sops)).
4. **Data**: a database is the app's own CNPG `Cluster`, and a PVC is backed up by VolSync ([Data](#data)).
5. **Commit, push, `just bootstrap::reconcile`**, then `flux get kustomizations -A`. The app's Kustomization must go `Ready` on its health checks.

## Build order

The order the cluster was built in, with each app's dependencies.

| # | App(s) | Namespace | Depends on | Notes |
| --- | --- | --- | --- | --- |
| 0 | *skeleton* | — | — | [Bootstrap](/kubernetes/getting-started/bootstrap) |
| 1 | `cilium` | `kube-system` | — | **Done 2026-11-18.** Adopt the helmfile release (one upgrade, all Cilium pods roll once: [what the takeover does](/kubernetes/getting-started/bootstrap#what-the-takeover-does-cilium-2026-11-18)). Add `networks.yaml`: the LB pool `10.0.12.1–254` and the L2 policy ([network map](/kubernetes/intro#network-map)). Adds the `sops` component with `cluster-secrets` ([shape](/kubernetes/flux/repository-architecture#cluster-secrets)) |
| 2 | `flux-operator`, `flux-instance` | `flux-system` | `flux-instance` → `flux-operator` | **Done 2026-11-19.** Adopt the helmfile releases (one upgrade each, and only the operator pod rolled: [what the takeover does](/kubernetes/getting-started/bootstrap#what-the-takeover-does-flux-2026-11-19)). `prune: disabled` on the whole `flux-system` chain so Flux can't uninstall itself ([why](/kubernetes/flux/intro#flux-must-never-uninstall-itself)). The helmfile now [reads chart, version and values from the manifests](/kubernetes/getting-started/bootstrap#one-source-of-truth-for-values), and `bootstrap/helmfile/values/` is gone |
| 3 | `gateway-api-crds` | `kube-system` | — | A `GitRepository` on `kubernetes-sigs/gateway-api` at `v1.6.3` plus a Kustomization on `config/crd/experimental` (for `ExternalAuth`), both in `ks.yaml` ([the CRDs as a Flux app](/kubernetes/getting-started/bootstrap#the-crds-as-a-flux-app)). `prune: disabled` on every object, because the injected `deletionPolicy` ignores `prune: false`. `just bootstrap::crds` reads the tag from it |
| 4 | **`longhorn`** | `longhorn-system` | — | **Done 2026-11-19.** Early, so every stateful app can depend on it. Privileged namespace, `defaultDataPath: /var/mnt/longhorn`, chart `1.13.0` from a `HelmRepository` (no OCI chart). `longhorn` is the default StorageClass with 2 replicas. No kubelet extra mount needed ([as built](/kubernetes/storage-longhorn#as-built-2026-11-19)) |
| 5 | `cert-manager`, then `cluster-issuer` | `cert-manager` | `cluster-issuer` → `cert-manager` | **Done 2026-11-19.** The Cloudflare DNS-01 issuer `cloudflare-cluster-issuer`, plus `cloudflare-cluster-issuer-staging` for tests. Chart v1.21.3 from OCI, which cert-manager only tests up to Kubernetes 1.36 ([why it's fine for now](/kubernetes/flux/repository-architecture#cert-managerappocirepositoryyaml)). Health-checked on the `HelmRelease` only, with no separate `Deployment` check. A staging `Certificate` went Ready through DNS-01 |
| 6 | `gateway` | `kube-system` | `cilium`, `gateway-api-crds`, `cluster-issuer` | **Done 2026-11-19.** The shared `Gateway` `main` on `10.0.12.1`, plus a production wildcard `Certificate` (apex + `*.<domain>`, Secret `${SECRET_DOMAIN/./-}-tls`). HTTP is a `301` to HTTPS for every host, and apps attach only to `sectionName: https`. Health-checked on the Certificate and, through `healthCheckExprs`, on the Gateway's `Programmed` condition ([as built](/kubernetes/getting-started/bootstrap#the-shared-gateway)). Tested end to end with a throwaway app and `curl --resolve`, before DNS records existed (they come from step 7) |
| 7 | `external-dns` | `network` | `gateway` | **Done 2026-11-19.** One instance, RFC2136 with a TSIG key to Technitium on `nyx` (Home DNS) only, from `gateway-httproute`. `sync` policy with the TXT registry (owner `home`), so it deletes only records it created. Chart `1.23.0` from a `HelmRepository` (no OCI chart). Tested with a throwaway `whoami` route: A + TXT records created, resolved over the tailnet, removed when the route was deleted ([as built](/kubernetes/dns-externaldns), [ADR 0001](https://github.com/lorenzorapetti/homelab/blob/main/docs/adr/0001-app-names-only-in-home-dns.md)) |
| 8 | `observability-db`, then `kube-prometheus-stack` | `observability` | `observability-db` → `longhorn`, `plugin-barman-cloud`; `kube-prometheus-stack` → `observability-db`, `gateway`, `longhorn`, `authentik` | **Done 2026-11-20.** Fresh install, chart `93.5.0` from OCI (`oci://ghcr.io/prometheus-community/charts`), Prometheus Operator `v0.95.2`. Privileged namespace for node-exporter. Prometheus (20Gi) and Alertmanager (1Gi) on Longhorn. Grafana keeps its state in the `grafana` database of the CNPG `Cluster` `observability-db`, shared by the namespace and archived to `s3://<bucket>/observability` on R2. Grafana, Prometheus and Alertmanager are chart-generated `HTTPRoute`s on the Shared Gateway. Prometheus and Alertmanager are the first apps behind Authentik forward auth (`ExternalAuth`, providers from a blueprint in Git). kube-proxy scraping off (Cilium), controller-manager/scheduler/etcd off until the control-plane metrics ticket ([Observability](/kubernetes/observability/intro)). The Prometheus Operator CRDs are their own release, `prometheus-operator-crds` `33.0.2`, with no dependencies, as cluster-template does it ([crds.yaml](https://github.com/onedr0p/cluster-template/blob/main/template/config/bootstrap/helmfile/crds.yaml.j2)). Apps with monitors depend on that, not on the stack ([why](/kubernetes/observability/intro#the-crds-come-first)) |
| 8a | `cloudnative-pg`, then `plugin-barman-cloud` | `cnpg-system` | `plugin-barman-cloud` → `cloudnative-pg`, `cert-manager` | **Done 2026-11-19.** The CloudNativePG operator, chart `0.29.2` (operator `1.30.2`), and the Barman Cloud backup plugin, chart `0.9.0` (plugin `v0.16.0`), both from OCI. Each app brings its own `Cluster`, `ObjectStore` and `ScheduledBackup` ([ADR 0002](https://github.com/lorenzorapetti/homelab/blob/main/docs/adr/0002-cloudnativepg-fresh-start.md), [ADR 0003](https://github.com/lorenzorapetti/homelab/blob/main/docs/adr/0003-backups-to-r2.md)). Monitoring on since 2026-11-20 (after step 8): the operator's PodMonitor, one PodMonitor per `Cluster`, and CNPG's Grafana dashboard. `cloudnative-pg` then also depends on `prometheus-operator-crds` ([Databases](/kubernetes/observability/intro#databases)) |
| 9 | `authentik-db`, then `authentik` | `auth` | `authentik-db` → `longhorn`, `plugin-barman-cloud`; `authentik` → `authentik-db`, `gateway` | **Done 2026-11-20.** Fresh install, chart `2026.8.6` from OCI. `authentik-db` is a one-instance CNPG `Cluster` (Postgres 18.7, 5Gi on Longhorn) archived to `s3://<bucket>/authentik` on R2, 30-day recovery window, nightly base backup. Non-secret settings are chart values (`authentik.*`). Secret ones come from the SOPS Secret `authentik-secrets` through `global.envFrom`, and the database password from CNPG's `authentik-db-app` through `global.env`. Email through Resend. No Redis (not needed since 2025.10). See [forward auth](#authentik-forward-auth-with-cilium-gateway) |
| 10 | `glance` | `glance` | `gateway`, `authentik` | **Done 2026-11-21.** Plain manifests, no chart: `v0.8.8`, config in a ConfigMap. At `home.<domain>`, behind forward auth. Starts as a page of links only ([Glance](/kubernetes/glance)) |
| 11 | `volsync`, then `forgejo-db`, then `forgejo` | `volsync-system`, `git` | `volsync` → `prometheus-operator-crds`, `snapshot-crds`; `forgejo-db` → `longhorn`, `plugin-barman-cloud`; `forgejo` → `forgejo-db`, `gateway`, `authentik`, `volsync` | **Done 2026-11-22.** Chart `17.3.3` from OCI, Forgejo 17.0.2 (`image.tag`; the chart defaults to the 15.x LTS), its own CNPG `Cluster` like authentik, no Redis. Data on PVC `forgejo`, backed up nightly by VolSync (chart `0.17.0`, restic to R2, Longhorn clones), the first app to use it ([Backups: volumes](/kubernetes/backups-volsync)). Login through authentik OIDC. SSH through a `TCPRoute` on a new `ssh` listener (port 22) of the shared Gateway ([open question 1](#open-questions), [Forgejo](/kubernetes/forgejo)) |
| 12 | `orbit-db`, then `orbit` | `orbit` | `orbit-db` → `longhorn`, `plugin-barman-cloud`; `orbit` → `orbit-db`, `gateway`, `authentik`, `volsync` | **Done 2026-11-23.** At `board.<domain>` ([Orbit](/kubernetes/orbit)) |
| 13 | `actual` | `actual` | `gateway`, `longhorn`, `authentik`, `volsync` | **Done 2026-11-24.** Plain manifests, at `budget.<domain>` ([Actual](/kubernetes/actual)) |

How the order is built:

- **1–6 are the platform.** Networking, Flux, storage, certificates and the Gateway come first, because every app needs a route, and most need a certificate or a volume.
- **Longhorn comes early (4).** Nothing stateful can start without it, and it is the one component with Talos-side prerequisites (extensions, user volume) that are worth testing on an empty cluster.
- **Stateless apps go before PVC-backed ones**, so the platform is proven before any app keeps data.

## Data

- **Postgres runs in the cluster** on CloudNativePG, with one `Cluster` per app ([ADR 0002](https://github.com/lorenzorapetti/homelab/blob/main/docs/adr/0002-cloudnativepg-fresh-start.md)).
- **Backups.** The cluster writes every backup to one Cloudflare R2 bucket. Postgres uses the CNPG Barman Cloud plugin, other volumes use VolSync with restic ([ADR 0003](https://github.com/lorenzorapetti/homelab/blob/main/docs/adr/0003-backups-to-r2.md)). Checking, testing and restoring Postgres backups: [Backups: Postgres](/kubernetes/backups-postgres). While all VMs share one host, Longhorn replicas aren't a backup.

## Authentik forward auth with Cilium Gateway

Apps without their own login sit behind Authentik. Cilium has no forward-auth middleware, but there are three ways to get the same result.

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

**3. Native OIDC in the app.** Apps that support it (Grafana, Forgejo, Orbit, Actual) log in against Authentik directly and need no gateway auth at all.

**Plan:** use (3) wherever the app supports it, and (1) for the rest. Fall back to (2) if (1) doesn't work with Authentik. **2026-11-20:** (1) is built for Prometheus and Alertmanager, with providers from an Authentik blueprint in Git ([as built](/kubernetes/observability/intro#authentik-forward-auth)). Compared with the sketch above, the backend is `authentik-server` port 80, because the embedded outpost runs inside the server and has no Service of its own. Each route also sends `/outpost.goauthentik.io` to it for the login callback, and a `ReferenceGrant` in `auth` allows both references. **2026-11-21:** (3) is built for Grafana, with its OAuth2 provider from a blueprint too ([Grafana login](/kubernetes/observability/grafana-login)).

## Open questions

1. ~~**Git server SSH.**~~ **Settled 2026-11-19: Forgejo, SSH as a `TCPRoute` on a port-22 listener of the shared Gateway.** Forgejo then has one name and one IP for HTTPS and SSH, and needs no DNS record beyond its `HTTPRoute`'s. Cilium 1.20 lists TCPRoute as supported (experimental CRD, already installed) ([Cilium Gateway API docs](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api/)). Still to prove when Forgejo lands. The fallback is a `LoadBalancer` Service on `10.0.12.2`, plus the `service` source in ExternalDNS.
2. **Authentik forward auth.** Does the `ExternalAuth` + embedded outpost combination actually work, including the login redirect? If not, use proxy mode for those apps ([above](#authentik-forward-auth-with-cilium-gateway)).
3. ~~**VM sizing while on one host.** 2 cores, 4.5GB RAM, 50GB system disk and 200GB Longhorn disk per VM is tight. Do I run fewer apps until hosts `.2`/`.3` exist, or start with a single Talos VM?~~ **Settled 2026-11-21: a second host.** `persephone` joined the Proxmox cluster and took `talos-3`. talos-1 and talos-2 grew to 6.5GB, and talos-3 to 4 cores and 8GB ([sizing](/kubernetes/getting-started/deploying-the-infrastructure#sizing), [Adding a Proxmox host](/kubernetes/getting-started/deploying-the-infrastructure#adding-a-proxmox-host)).
4. ~~**Longhorn on Talos 1.14.** Is the kubelet extra mount for `/var/mnt/longhorn` needed, and does `!system_disk` select only the data disk?~~ **Settled 2026-11-19: no extra mount.** The selector picks only `sdb` (215 GB, `xfs` at `/var/mnt/longhorn`), and volumes attach on any node ([as built](/kubernetes/storage-longhorn#as-built-2026-11-19)).
5. **topf and Talos 1.14.** topf officially lists Talos v1.13. Is that acceptable, or should I pin Talos to 1.13 until topf lists 1.14?
6. **UEFI vs SeaBIOS** for the `nocloud` raw image in Terraform, and the image's real compression (`.raw.xz` vs `zst`).
7. **CoreDNS.** Keep it Talos-managed, or disable it and manage the chart with Flux like cluster-template?
8. ~~**Flux version pin.** `2.10.x` (deliberate minor upgrades) or the chart default `2.x`?~~ **Settled 2026-11-19: `2.10.x`.** A Flux minor upgrade stays a deliberate commit ([The FluxInstance](/kubernetes/flux/intro#the-fluxinstance)).
9. **Pod Security.** Keep Talos's `baseline` default and label privileged namespaces, or delete the admission config like cluster-template?
10. ~~**OCI charts.**~~ **Settled 2026-11-24.** Each app checks for an OCI chart when it's added ([step 3](#adding-one-app)). Longhorn doesn't publish one (checked 2026-11-19).
11. **Flux webhook receiver.** Add a GitHub → Flux `Receiver` through the Gateway (and revisit `networkPolicy`) instead of polling every minute?
12. ~~**Flux alerts.** Flux 2.10 notification `Alert`/`Provider` are `v1` now. Where should alerts go?~~ **Settled 2026-11-21: to Alertmanager, and on to Pushover**, like every other alert ([Alerting](/kubernetes/observability/alerting)). Still to wire up: a notification-controller `Provider` of type `alertmanager`, or `PrometheusRule`s on Flux's metrics.
13. ~~**ExternalDNS.**~~ **Settled 2026-11-19: ExternalDNS, to Home DNS only** (step 7, [as built](/kubernetes/dns-externaldns)). A wildcard couldn't give a non-Gateway service its own address. Cloudflare gets no app records; tailnet devices reach Technitium through split DNS ([ADR 0001](https://github.com/lorenzorapetti/homelab/blob/main/docs/adr/0001-app-names-only-in-home-dns.md)).
14. **Renovate coverage.** Its `flux`, `kubernetes` and `helm-values` managers already match `kubernetes/**`. Add `bootstrap/helmfile/**`, `talos/topf.yaml` and `infrastructure/`? cluster-template annotates `topf.yaml` versions with `# renovate:` comments ([topf.yaml](https://github.com/onedr0p/cluster-template/blob/main/template/config/talos/topf.yaml.j2)) and uses `home-operations/renovate-presets` ([`.renovaterc.json5`](https://github.com/onedr0p/cluster-template/blob/main/.renovaterc.json5)).
