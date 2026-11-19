# App names live only in Home DNS; the tailnet reaches it through Split DNS

App names (`<app>.lorenzolab.com`) point at the Gateway address `10.0.12.1` and are published by ExternalDNS to Home DNS (Technitium on `nyx`) only. Tailnet devices get the same answers through Split DNS: the tailnet nameserver for `lorenzolab.com` is `nyx`'s tailnet address `100.111.201.33`, the same server LAN clients reach as `10.0.1.30`. Tailnet devices then reach the Gateway through the subnet route `hecate` already advertises, so Tailscale never runs in the cluster and there is one answer per name everywhere. Public DNS (Cloudflare) keeps only names that are meant to be public, plus cert-manager's DNS-01 challenges.

## Considered options

- **Split horizon, as before: Cloudflare serves a tailnet IP.** Something with a `100.x` address must then forward to the Gateway: `nyx`/Traefik as a proxy, or the Tailscale Kubernetes operator exposing the Gateway. Both add a component and a second ExternalDNS instance with its own Cloudflare token, for no gain once the subnet route exists.
- **Cloudflare also serves `10.0.12.1`.** This puts private IPs in public DNS. Off-site resolvers with DNS-rebind protection drop such answers, and it still needs a second ExternalDNS instance.
- **Static wildcard records.** These can't give a non-Gateway service its own address, and they create names for apps that don't exist.

## Consequences

- Restricted devices (phones) need a tailnet grant to `10.0.12.1:80,443`. DNS needs nothing new: they already reach `tag:dns` on 53.
- Home DNS answers LAN addresses for everything, including `nyx`'s own services (`*.home.lorenzolab.com` → `10.0.1.30`, Traefik on `nyx`). So `hecate` also advertises `10.0.1.30/32`, and phones get `10.0.1.30:80,443`. Traffic to `nyx`'s services goes through `hecate` even though `nyx` is on the tailnet itself: one extra LAN hop, in exchange for one answer per name.
- Split DNS still points at `nyx`'s tailnet address, not `10.0.1.30`, so names keep resolving when `hecate` is down.
- Home DNS must also hold the public `lorenzolab.com` names (e.g. `parts`), because tailnet devices ask it about the whole zone.
- If `nyx` is down, tailnet devices can't resolve anything in `lorenzolab.com`; if `hecate` is down, they can resolve but not reach LAN addresses.
- Forgejo SSH goes through a TCPRoute on the Shared Gateway, so it shares the HTTPS name and IP and needs no record of its own.
