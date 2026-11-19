# Homelab

The language of this homelab: its network, its Kubernetes cluster and how services are reached from home and from the tailnet.

## Language

### Network

**API VIP**:
The floating address (`10.0.11.10`) the Talos control-plane nodes share for the Kubernetes API.
_Avoid_: VIP (on its own), cluster IP

**Gateway address**:
The LoadBalancer address (`10.0.12.1`) of the Shared Gateway, where every app's HTTP(S) traffic enters the cluster.
_Avoid_: VIP, ingress IP

**Shared Gateway**:
The one Gateway (`main` in `kube-system`) that all apps attach their routes to.
_Avoid_: ingress, Traefik

**Subnet router**:
A tailnet device that makes LAN ranges reachable from the tailnet. Today that is `hecate`.
_Avoid_: exit node

### DNS

**Public DNS**:
The `lorenzolab.com` zone at Cloudflare, which anyone can query. It holds only names meant to be reachable from the internet, plus cert-manager's DNS-01 challenges.

**Home DNS**:
The Technitium server on `nyx`: `10.0.1.30` on the LAN, `100.111.201.33` on the tailnet. The one primary for `lorenzolab.com`, and the only place app names live.
_Avoid_: local DNS

**Split DNS**:
The tailnet setting that sends `lorenzolab.com` queries from tailnet devices to Home DNS, so they get the same answers as the LAN.
_Avoid_: split horizon (the old scheme, where Public DNS gave tailnet clients a different answer)
