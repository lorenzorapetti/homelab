# App names live only in Home DNS; the tailnet reaches it through Split DNS

App names (`<app>.lorenzolab.com`) point at the Gateway address `10.0.12.1` and are published by ExternalDNS to Home DNS (Technitium on `nyx`) only. Tailnet devices get the same answers through Split DNS: the tailnet nameserver for `lorenzolab.com` is `nyx`'s tailnet address `100.111.201.33`, the same server LAN clients reach as `10.0.1.30`. Tailnet devices then reach the Gateway through the subnet route `hecate` already advertises, so Tailscale never runs in the cluster and there is one answer per name everywhere. Public DNS (Cloudflare) keeps only names that are meant to be public, plus cert-manager's DNS-01 challenges.

## Considered options

- **Split horizon, as before: Cloudflare serves a tailnet IP.** Something with a `100.x` address must then forward to the Gateway: `nyx`/Traefik as a proxy, or the Tailscale Kubernetes operator exposing the Gateway. Both add a component and a second ExternalDNS instance with its own Cloudflare token, for no gain once the subnet route exists.
- **Cloudflare also serves `10.0.12.1`.** This puts private IPs in public DNS. Off-site resolvers with DNS-rebind protection drop such answers, and it still needs a second ExternalDNS instance.
- **Static wildcard records.** These can't give a non-Gateway service its own address, and they create names for apps that don't exist.

## Consequences

- Restricted devices (phones) need a tailnet grant to `10.0.12.1:80,443`. DNS needs nothing new: they already reach `tag:dns` on 53.
- Home DNS must also hold the public `lorenzolab.com` names (e.g. `parts`), because tailnet devices ask it about the whole zone.
- If `nyx` is down, tailnet devices can't resolve apps; if `hecate` is down, they can resolve but not reach them.
- Split DNS goes to `nyx`'s tailnet address, not through `hecate`. An earlier draft advertised `10.0.1.30/32` through `hecate` before it was clear that `10.0.1.30` and `100.111.201.33` are the same server.
- Forgejo SSH goes through a TCPRoute on the Shared Gateway, so it shares the HTTPS name and IP and needs no record of its own.
