---
sidebar_position: 9
sidebar_label: "Remote access: Tailscale"
---

# Remote access over Tailscale

The Talos nodes are not on the tailnet. The Proxmox host `hecate` is, and it works as a Tailscale [subnet router](https://tailscale.com/kb/1019/subnets) for the cluster ranges. Away from home, `kubectl`, `talosctl`, the Proxmox UI and `just tf::*` work through it unchanged: kubeconfig, talosconfig and the Terraform variables keep their LAN addresses. Nothing in Talos or the cluster is involved.

## Advertised routes

Addresses come from the [network map](/kubernetes/intro#network-map).

| Route | What it reaches |
| --- | --- |
| `10.0.10.1/32` | hecate's LAN address: Proxmox UI and API (`proxmox_endpoint`), SSH (`proxmox_host`) |
| `10.0.11.0/24` | `talos-1`…`talos-3` (Talos API on `:50000`) and the Kubernetes API VIP `10.0.11.10:6443` |
| `10.0.12.0/24` | Cilium LoadBalancer IPs, including the shared Gateway on `10.0.12.1` |
| `10.0.1.30/32` | `nyx` on the LAN: Technitium (Home DNS) and its Traefik for `*.home.lorenzolab.com` (e.g. the Attic cache at `cache.home…`) |

`10.0.10.1/32` is hecate's own address. hecate is reachable by its tailnet name anyway, but routing the LAN address means the Terraform variables (`https://10.0.10.1:8006/`) don't need a tailnet-only variant. Packets for it arrive on `tailscale0` and are delivered locally.

`10.0.1.30/32` is there because Home DNS answers LAN addresses for everything, `nyx`'s own services included ([DNS](#dns)). `nyx` is on the tailnet itself, but its names resolve to `10.0.1.30`, so that address has to be reachable. Traffic to it goes through hecate: one extra LAN hop.

The rest of `10.0.0.0/16` (router, DHCP clients) is deliberately not advertised.

## DNS

Tailnet devices resolve `lorenzolab.com` the same way the LAN does, through **split DNS**: in the admin console under **DNS → Nameservers**, `100.111.201.33` (`nyx`'s tailnet IP, the same Technitium as `10.0.1.30`) is restricted to `lorenzolab.com`. There is no global nameserver override, so other domains use each device's own resolver. App records come from ExternalDNS ([DNS: ExternalDNS](/kubernetes/dns-externaldns)), and Cloudflare has none of them ([ADR 0001](https://github.com/lorenzorapetti/homelab/blob/main/docs/adr/0001-app-names-only-in-home-dns.md)).

Split DNS uses `nyx`'s tailnet IP rather than `10.0.1.30`, so names still resolve when hecate is down. Devices need `--accept-dns` (the default) for split DNS, and `--accept-routes` to reach the answers.

## Tailnet policy

The policy lives in the Tailscale admin console, not in this repo. The parts that matter here:

- hecate carries **`tag:hypervisor`** (Proxmox node) and **`tag:exit`** (exit nodes and subnet routers). A tagged device gets the union of its tags' grants. `tag:exit` adds nothing beyond DNS, so hecate's access is the same as with `tag:hypervisor` alone.
- `autoApprovers.routes` approves `10.0.0.0/16` for `tag:exit`. Any narrower route inside it is approved automatically, so the routes above need no click in the console. With only `tag:hypervisor`, they would stay "awaiting approval".
- The workstation grant (`group:admin` with `posture:workstation`, `dst: ["*"]`) covers approved subnet routes. Laptops and desktops reach everything in the table.
- Phones (`group:admin` without the workstation posture) get `tcp:80`/`tcp:443` to two named `hosts`: `gateway-address` (`10.0.12.1/32`) and `nyx-lan` (`10.0.1.30/32`). DNS needs no extra grant: split DNS goes to `nyx`'s tailnet IP, and phones already reach `tag:dns` on 53. Forgejo SSH from a phone would need `tcp:22` on `gateway-address`.

## Setting up hecate

hecate joins with an auth key from **Add device → Linux server**: tags `tag:hypervisor` and `tag:exit`, not reusable, not ephemeral. Tagged devices have key expiry disabled ([tags](https://tailscale.com/kb/1068/tags)).

As root on hecate, from the LAN or the Proxmox console (not over Tailscale: `logout` drops the connection):

```sh
# Forwarding for the subnet router
echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-tailscale.conf
sysctl -p /etc/sysctl.d/99-tailscale.conf

# Join (or move from another tailnet). --reset clears flags from an earlier `up`.
tailscale logout
tailscale up --reset --auth-key=tskey-auth-XXXX \
  --advertise-routes=10.0.10.1/32,10.0.11.0/24,10.0.12.0/24,10.0.1.30/32
```

The tags come from the auth key, so there is no `--advertise-tags`. `tailscale set --advertise-routes=…` replaces the whole list, so always pass all four routes.

### Warnings from `tailscale up`

- **"IPv6 forwarding is disabled"**: ignored on purpose. Only IPv4 routes are advertised and hecate isn't an exit node. Enabling `net.ipv6.conf.all.forwarding` would also make Linux stop accepting router advertisements, which can cost hecate its SLAAC address (unless `accept_ra = 2` is set on `vmbr0`).
- **"UDP GRO forwarding is suboptimally configured on vmbr0"**: fixed with the `ethtool` settings from [Tailscale's performance guide](https://tailscale.com/s/ethtool-config-udp-gro), made permanent in the `vmbr0` stanza of `/etc/network/interfaces` (ifupdown2 doesn't care about option order):

  ```
  iface vmbr0 inet static
          post-up ethtool -K vmbr0 rx-udp-gro-forwarding on rx-gro-list off
          address 10.0.10.1/16
          ...
  ```

## Clients

Linux clients ignore subnet routes until told otherwise ([subnets](https://tailscale.com/kb/1019/subnets)). `tailscale status` warns "Some peers are advertising routes but --accept-routes is false":

```sh
sudo tailscale set --accept-routes
```

Check that the routes are approved, and that the cluster goes through Tailscale:

```sh
tailscale status --json | jq '.Peer[] | select(.HostName=="hecate") | {Tags, PrimaryRoutes}'
ip route get 10.0.11.10    # → dev tailscale0 table 52
```

**At home**, with `--accept-routes` on, Tailscale's routing table 52 takes priority over the LAN route, so cluster traffic hairpins through hecate over Tailscale. It works, with one extra hop.

## Verified

2026-11-19, from a workstation on another network: `ip route get 10.0.11.10` went through `tailscale0`, `kubectl get nodes` listed all three nodes `Ready` through the VIP, `talosctl -n 10.0.11.1 version` answered, and `https://10.0.10.1:8006/` returned HTTP 200.

Later the same day, after split DNS and the `10.0.1.30/32` route: `tailscale dns status` listed `lorenzolab.com -> 100.111.201.33`, `cache.home.lorenzolab.com` resolved to `10.0.1.30` and returned HTTP 200, and an ExternalDNS test record `whoami.lorenzolab.com` resolved to `10.0.12.1` and returned HTTP 200 through the Gateway.

## Later

- **Subnet router failover.** `persephone` (`10.0.10.2`, running `talos-3`) is on the tailnet but advertises no routes. hecate is still the only subnet router. Losing hecate takes etcd quorum down anyway (two of the three control-plane VMs run on it), so a second router adds little today. If that changes, advertise the same routes from persephone for [subnet router failover](https://tailscale.com/kb/1115/high-availability).
- **Tailscale Kubernetes operator.** The policy already reserves `tag:k8s-operator`, `tag:k8s` and the `tag:k8s-gateway*` tags: the operator can expose the Cilium Gateway and individual Services on the tailnet with MagicDNS names, and its API server proxy gives `kubectl` access tied to Tailscale identity. It doesn't cover `talosctl`, so the subnet route stays.
- **`siderolabs/tailscale` extension on Talos** (`tag:k8s-node`). Not planned: every node would need an auth key and extra `certSANs`, for nothing the subnet route doesn't already give.
