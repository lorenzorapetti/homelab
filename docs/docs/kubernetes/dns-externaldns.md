---
sidebar_position: 5.5
sidebar_label: "DNS: ExternalDNS"
---

# DNS: ExternalDNS

App names come from [ExternalDNS](https://github.com/kubernetes-sigs/external-dns). It reads the hostnames of every `HTTPRoute` on the shared Gateway and writes an A record for each, pointing at the Gateway address `10.0.12.1`, into **Home DNS**: Technitium on `nyx` (`10.0.1.30`). Nothing goes to Cloudflare. Tailnet devices see the same records through split DNS ([Remote access: DNS](/kubernetes/remote-access-tailscale#dns)). The reasons, and the options that were turned down, are in [ADR 0001](https://github.com/lorenzorapetti/homelab/blob/main/docs/adr/0001-app-names-only-in-home-dns.md).

## As built (2026-11-19)

The app is `kubernetes/apps/network/external-dns/` in the `network` namespace (step 7 of the [migration](/kubernetes/migration)). It `dependsOn` `gateway` and is health-checked on its `HelmRelease`.

| Setting | Value | Why |
| --- | --- | --- |
| Chart | `external-dns` `1.23.0` (app `v0.23.0`), `HelmRepository` `https://kubernetes-sigs.github.io/external-dns` | No OCI chart: `registry.k8s.io/external-dns/charts/external-dns` has no tags (checked 2026-11-19) |
| Provider | `rfc2136`, host `10.0.1.30:53`, zone `${SECRET_DOMAIN}` | Built into ExternalDNS, so no webhook sidecar. The TSIG key can only change this zone, while a Technitium API token could do anything on the server |
| TSIG | key `external-dns`, `hmac-sha256` | The secret is in `app/secret.sops.yaml` (Secret `external-dns-tsig`, key `secret`) and reaches the container as `EXTERNAL_DNS_RFC2136_TSIG_SECRET` |
| `--rfc2136-axfr` | on | `sync` needs a zone transfer to list existing records. Without it, ExternalDNS behaves as if the zone were empty |
| `--rfc2136-min-ttl` | `5m` | Without it, records are written with TTL 0 and never cached |
| Source | `gateway-httproute` only | The target comes from the Gateway's `status.addresses`, so there is no `--default-targets`. Forgejo SSH will be a `TCPRoute` on the same Gateway and shares its `HTTPRoute`'s name |
| Policy | `sync`, TXT registry, `--txt-owner-id=home`, `--domain-filter=${SECRET_DOMAIN}` | Deletes a record when its route goes away, but only records with its own TXT owner record (`a-<name>`). Hand-made records (`parts`, the `*.home` wildcard) and dnsweaver's are never touched |
| `--events` | on | Changes are picked up within seconds rather than at the next 1-minute interval |

## Technitium side

Settings on `nyx`, not in this repo:

- **Settings → TSIG:** the key `external-dns`, HMAC-SHA256.
- **Zones → `lorenzolab.com` → Zone Options:**
  - *Zone Transfer:* network ACL `10.0.11.0/24` (pod traffic leaves through the Talos node IPs) and the TSIG key `external-dns`.
  - *Dynamic Updates:* the same ACL, plus the security policy `external-dns` | `*.lorenzolab.com` | `A,TXT`. A `*.` domain covers every name under it.
- **TCP on port 53.** Zone transfers only work over TCP. systemd-resolved's stub listener held TCP `127.0.0.53:53`/`127.0.0.54:53`, which made Technitium's `0.0.0.0:53` TCP bind fail; only its IPv6-only `[::]:53` socket was left, so IPv4 TCP got "connection refused". `nyx`'s NixOS config turns the stub listener off and points `nyx` at its own Technitium:

  ```nix
  services.resolved.settings.Resolve.DNSStubListener = false;
  networking.nameservers = [ "127.0.0.1" ];
  ```

  Technitium only retries the bind when it starts: `systemctl restart technitium-dns-server` after changing this. Check with `dig +tcp lorenzolab.com SOA @10.0.1.30`.

## Tested

2026-11-19, with a throwaway `whoami` Deployment, Service and `HTTPRoute` for `whoami.lorenzolab.com`:

1. ExternalDNS added `whoami.lorenzolab.com A 10.0.12.1` and the TXT record `a-whoami.lorenzolab.com` (`heritage=external-dns,external-dns/owner=home,…`).
2. From a workstation away from home, the name resolved through split DNS, and `https://whoami.lorenzolab.com/` returned HTTP 200 with the wildcard certificate.
3. Deleting the `HTTPRoute` removed both records (`NXDOMAIN`). `parts` and the `*.home` wildcard were untouched.

## Checking it

```sh
kubectl -n network logs deploy/external-dns --tail=20   # "All records are already up to date"
dig +short <app>.lorenzolab.com @10.0.1.30                # → 10.0.12.1
```

`failed to fetch records via AXFR … connection refused` means Technitium isn't taking TCP on port 53 again (see above). `NOTAUTH` or `REFUSED` points at the TSIG key or the zone's ACLs.

## Alerts

Prometheus scrapes ExternalDNS on port `http` (7979) every 30s, through the chart's ServiceMonitor (`serviceMonitor.enabled`; Prometheus `job` `external-dns`). The rules are in `app/prometheusrule.yaml`:

| Alert | Fires when | For | Severity |
| --- | --- | --- | --- |
| `ExternalDNSSyncErrors` | registry, source or apply errors in the last 10 minutes | 10m | warning |
| `ExternalDNSSyncStale` | no successful sync for 15 minutes | 5m | warning |

What the errors mean, for this setup:

- **Registry errors** (`external_dns_registry_errors_total`): listing the zone failed, which for `rfc2136` is the AXFR from Home DNS. Usually Technitium is down, isn't taking TCP on 53, or refuses the transfer (ACL or TSIG).
- **Source errors** (`external_dns_source_errors_total`): reading HTTPRoutes from the API server failed.
- **Apply errors** (`external_dns_controller_consecutive_soft_errors`): a dynamic update was refused, typically by the zone's update security policy (a record type or name it doesn't allow).

The rules are written per pod, not for this instance by name, so a second ExternalDNS (for example one writing to Public DNS, if [ADR 0001](https://github.com/lorenzorapetti/homelab/blob/main/docs/adr/0001-app-names-only-in-home-dns.md) ever changes) is covered as soon as its chart's ServiceMonitor is on.

When one fires, the logs say which: `kubectl -n network logs deploy/external-dns --tail=50`, then the checks above. **Cluster Health**'s **Certificates and ExternalDNS** row shows the errors over the selected range and the time since the last successful sync.
