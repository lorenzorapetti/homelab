---
sidebar_position: 5.8
sidebar_label: Glance
---

# Glance

[Glance](https://github.com/glanceapp/glance) is the homelab's start page, at `https://home.<domain>`. For now it is one page of links: every app in the cluster, plus the Proxmox hosts `hecate` and `persephone`.

## As built

Plain manifests in `kubernetes/apps/glance/glance/app/`, no Helm chart: a single Go binary with one config file doesn't need one.

- **Deployment** `glance`, image `docker.io/glanceapp/glance:v0.8.8`, one replica. It runs as `nobody` with a read-only root filesystem, and its probes hit `/api/healthz`.
- **Config**: `glance.yml`, mounted at `/app/config/glance.yml` (the path the image's entrypoint reads) from a `configMapGenerator`. The hash suffix rolls the pod whenever the file changes. Flux substitutes `${SECRET_DOMAIN}` in it like in any other manifest.
- **Route**: `HTTPRoute` `glance` on the Shared Gateway. ExternalDNS publishes `home.<domain>` to Home DNS from it. ExternalDNS only manages records it owns, so a hand-made `home` record in Technitium blocks it: delete that first.
- **Auth**: Glance has no login, so the route has the same `ExternalAuth` filter as Prometheus and the Longhorn UI, `authentik Admins` only ([Authentik forward auth](/kubernetes/observability/intro#authentik-forward-auth)). The `Glance` provider and application are in `forward-auth.yaml`, and `glance` is in ReferenceGrant `authentik-forward-auth`.

Glance exports no metrics. Its logs are in Loki under `{app="glance"}`, and the stack's generic pod rules cover crash loops and a pod that isn't ready.

## Adding a link

Add it to the right group of the `bookmarks` widget in `glance.yml`. Icons use a prefix: `sh:` for [selfh.st icons](https://selfh.st/icons/), `di:` for [dashboard-icons](https://github.com/homarr-labs/dashboard-icons), `si:` for Simple Icons. A name that doesn't exist shows no icon, so check it first, for example `curl -sI https://cdn.jsdelivr.net/gh/selfhst/icons/png/<name>.png`.
