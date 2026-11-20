---
sidebar_position: 8.5
sidebar_label: Useful commands
---

# Useful commands

A cheat sheet for debugging the cluster, top-down: the Talos nodes, Kubernetes, Flux, then the components that run on top. Run everything from the repo root inside `devenv shell`: it provides every CLI here and sets `TALOSCONFIG` and `KUBECONFIG` to the repo's files.

Addresses come from the [network map](/kubernetes/intro#network-map): `talos-1`…`talos-3` are `10.0.11.1`–`10.0.11.3`.

## Where to start

When something is broken and you don't know where:

```sh
talosctl -n 10.0.11.1 health                    # nodes, etcd, kubelet, API server
kubectl get nodes -o wide                       # all Ready?
flux get all -A --status-selector ready=false   # anything Flux can't reconcile
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
kubectl get events -A --sort-by=.lastTimestamp | tail -30
```

If `kubectl` itself doesn't answer, the problem is below Kubernetes: go to [Talos](#talos).

## Talos

The talosconfig context lists all three nodes as `nodes`, so a `talosctl` command without `-n` runs on **every node** and prefixes each line with the node's IP. Pass `-n <ip>` to target one node. The endpoints are the node IPs, not the VIP: the Talos API works even when Kubernetes is down.

### Health and overview

```sh
talosctl -n 10.0.11.1 health          # cluster-wide checks, run from one node
talosctl -n 10.0.11.1 dashboard       # TUI: CPU, memory, processes, logs (arrows switch node)
talosctl version                      # client and per-node Talos versions
talosctl get members                  # nodes as Talos discovery sees them
talosctl services                     # apid, containerd, cri, etcd, kubelet, … and their state
talosctl -n 10.0.11.1 service kubelet # one service's state and recent events
```

### Logs

```sh
talosctl -n 10.0.11.1 dmesg -f                  # kernel log, follow
talosctl -n 10.0.11.1 logs kubelet -f           # a Talos service's log
talosctl -n 10.0.11.1 logs etcd --tail 100
talosctl -n 10.0.11.1 containers --namespace cri               # pod containers
talosctl -n 10.0.11.1 logs --namespace cri <container-id>      # a pod container's log, even if the API server is down
talosctl -n 10.0.11.1 events                    # Talos machine events (boot, config, upgrades)
```

### etcd

```sh
talosctl -n 10.0.11.1 etcd members      # three members expected
talosctl etcd status                    # leader, DB size, raft index per node
talosctl etcd alarm list                # NOSPACE / CORRUPT alarms
talosctl -n 10.0.11.1 etcd snapshot etcd.snapshot   # backup before anything risky
```

### Resources (the Talos "API objects")

`talosctl get <type>` reads the node's state the way `kubectl get` reads the cluster's. `talosctl get rd` lists every type.

```sh
talosctl -n 10.0.11.1 get machineconfig -o yaml   # the applied config (contains secrets)
talosctl get extensions                           # qemu-guest-agent, iscsi-tools, util-linux-tools
talosctl get addresses                            # IPs on each link, including the VIP 10.0.11.10
talosctl get links
talosctl get routes
talosctl get resolvers                            # DNS servers in use
talosctl get disks
talosctl get volumestatus                         # system volumes and the longhorn user volume
talosctl get mountstatus u-longhorn
talosctl get staticpods                           # kube-apiserver, controller-manager, scheduler
```

### Processes, files and network

There is no shell on Talos. These replace the usual `ps`, `cat`, `ls`, `ss` and `tcpdump`:

```sh
talosctl -n 10.0.11.1 processes -s cpu     # sorted by CPU (default: memory)
talosctl -n 10.0.11.1 memory
talosctl -n 10.0.11.1 stats --namespace cri # per-container CPU and memory for pods
talosctl -n 10.0.11.1 ls /var/log
talosctl -n 10.0.11.1 read /proc/meminfo
talosctl -n 10.0.11.1 netstat -tlp          # listening TCP sockets (-n is --nodes here, not numeric)
talosctl -n 10.0.11.1 pcap -i eth0 -o out.pcap   # open with wireshark
talosctl -n 10.0.11.1 time                  # NTP sync
```

### Config and lifecycle

Config changes go through topf (see [Install Talos](/kubernetes/getting-started/install-talos)), not `talosctl apply-config`:

```sh
just talos::diff                        # what topf apply would change
just talos::apply                       # diff, confirm, apply
talosctl -n <ip> reboot
talosctl -n <ip> rollback               # back to the previous Talos version after a bad upgrade
talosctl -n 10.0.11.1 support           # support bundle (zip of logs and resources) for bug reports
```

## Kubernetes

There is no metrics-server, so `kubectl top` doesn't work. Use Grafana ([Observability](/kubernetes/observability/intro)) or `talosctl stats --namespace cri`.

### Nodes and API server

```sh
kubectl get nodes -o wide
kubectl describe node talos-1                 # conditions, taints, allocated resources, events
kubectl get --raw '/readyz?verbose'           # API server health checks one by one
kubectl get pods -n kube-system               # static pods, coredns, cilium
kubectl api-resources | grep -i <kind>        # find a CRD's short name and group
```

### Pods

```sh
kubectl get pods -A -o wide
kubectl get pods -A | grep -vE 'Running|Completed'
kubectl describe pod -n <ns> <pod>            # the Events at the bottom explain most Pending/CrashLoop pods
kubectl logs -n <ns> <pod> -c <container> -f
kubectl logs -n <ns> <pod> --previous         # the log before the last crash
kubectl logs -n <ns> deploy/<name> --all-containers --tail=100
kubectl exec -it -n <ns> <pod> -- sh
kubectl get pod -n <ns> <pod> -o yaml | yq '.status'
```

### Events

```sh
kubectl get events -A --sort-by=.lastTimestamp
kubectl get events -A --field-selector type=Warning
kubectl events -n <ns> --for pod/<pod> --watch
```

### Workloads

```sh
kubectl rollout status -n <ns> deploy/<name>
kubectl rollout restart -n <ns> deploy/<name>
kubectl rollout history -n <ns> deploy/<name>
kubectl get deploy,sts -A | grep -v '\([0-9]\+\)/\1'   # anything not fully ready
kubectl get ds -A                                       # DaemonSets: DESIRED = READY?
```

Flux reverts manual changes to anything it manages at the next reconcile. To edit something live while debugging, [suspend](#suspend-and-resume) its Kustomization or HelmRelease first.

### Network and DNS from inside the cluster

```sh
# A throwaway pod with curl, dig, nslookup, tcpdump, …
kubectl run tmp-shell --rm -it --image=nicolaka/netshoot -- bash

# From that shell:
#   dig <svc>.<ns>.svc.cluster.local
#   curl -v http://<svc>.<ns>:<port>

kubectl get svc,endpointslices -n <ns>        # a Service with no endpoints = selector doesn't match
kubectl port-forward -n <ns> svc/<name> 8080:<port>
```

### Debugging a node from Kubernetes

A privileged pod on the node's namespaces, with the host filesystem at `/host`. It must run in a namespace that allows privileged pods, such as `kube-system`:

```sh
kubectl debug -n kube-system node/talos-1 -it --image=nicolaka/netshoot --profile=sysadmin
```

Delete the leftover `node-debugger-*` pod afterwards.

### Storage

```sh
kubectl get pvc -A                    # anything not Bound?
kubectl get pv
kubectl describe pvc -n <ns> <name>   # provisioning errors
kubectl get volumeattachments         # which node a volume is attached to
```

### RBAC

```sh
kubectl auth can-i --list --as=system:serviceaccount:<ns>:<sa>
kubectl auth can-i get secrets -n <ns> --as=system:serviceaccount:<ns>:<sa>
```

## Flux

How the Kustomizations are laid out: [Repository Architecture](/kubernetes/flux/repository-architecture). `ks` and `hr` are the CLI's short names for `kustomization` and `helmrelease`.

### State

```sh
flux check                                       # CLI vs controllers, CRDs, prerequisites
flux version                                     # CLI, distribution and each controller
flux get all -A                                  # sources, Kustomizations, HelmReleases
flux get all -A --status-selector ready=false    # only what's failing
flux get sources all -A                          # GitRepository, OCIRepository, HelmRepository
flux get ks -A
flux get hr -A
flux get ks -A --watch                           # live, like during a reconcile
flux stats -A                                    # counts of ready/failed/suspended per kind
kubectl -n flux-system get fluxinstance flux     # the Flux Operator's view: Ready, REVISION
kubectl -n flux-system get fluxreport flux -o yaml
```

### Why is it failing?

```sh
flux events -A --watch                                      # events from every Flux object
flux events -n <ns> --for Kustomization/<name>
flux events -n <ns> --for HelmRelease/<name>
flux logs -A --level=error                                  # all controllers, errors only
flux logs -A --kind=Kustomization --name=<name> --follow
kubectl describe ks -n <ns> <name>                          # conditions in full
kubectl describe hr -n <ns> <name>
```

A Kustomization that waits for another (`dependsOn`) shows "dependency … is not ready". Follow the chain until you reach the one that is actually failing.

### What does Flux manage?

```sh
flux tree ks flux-system -n flux-system           # everything, as a tree of Kustomizations
flux tree ks <name> -n <ns>                       # one app's objects
flux trace -n <ns> <name> --kind=Deployment --api-version=apps/v1   # which Kustomization/HelmRelease and source made this object
```

### Reconciling

Flux polls on its own. These make it act now:

```sh
just bootstrap::reconcile                                  # = flux reconcile ks flux-system -n flux-system --with-source
flux reconcile source git flux-system -n flux-system       # only pull the repo
flux reconcile ks <name> -n <ns> --with-source             # pull, then apply one Kustomization
flux reconcile hr <name> -n <ns> --with-source             # fetch the chart, then upgrade
flux reconcile hr <name> -n <ns> --force                   # rerun the Helm upgrade even if nothing changed
flux reconcile hr <name> -n <ns> --reset                   # clear the retry counter after failed upgrades
```

### Suspend and resume

Stops Flux from reverting manual changes while you debug. Don't forget to resume:

```sh
flux suspend ks <name> -n <ns>
flux suspend hr <name> -n <ns>
flux get all -A | grep -i suspended          # anything left suspended?
flux resume ks <name> -n <ns>
flux resume hr <name> -n <ns>
```

### Previewing a change

```sh
# Diff a local path against the cluster, before pushing
flux diff ks <name> -n <ns> --path ./kubernetes/apps/<ns>/<app>/app

kubectl kustomize kubernetes/apps/<ns>/<app>/app   # render without touching the cluster
```

### Helm releases

helm-controller stores releases like the Helm CLI does, so `helm` can read them:

```sh
helm list -A
helm history -n <ns> <release>           # every revision and why it failed
helm get values -n <ns> <release>        # the values Flux passed
helm get manifest -n <ns> <release>
```

## Components

### Cilium and Gateway

```sh
cilium status --wait
cilium config view
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --verbose
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg service list
kubectl get ciliumloadbalancerippools,ciliuml2announcementpolicies
kubectl get svc -A --field-selector spec.type=LoadBalancer        # EXTERNAL-IP from 10.0.12.0/24
kubectl -n kube-system get gateway main                           # PROGRAMMED True, 10.0.12.1
kubectl get httproute -A
kubectl describe httproute -n <ns> <name>                         # Accepted / ResolvedRefs conditions
```

The full connectivity test is in [Bootstrap: Checking Cilium](/kubernetes/getting-started/bootstrap#checking-cilium).

### Certificates (cert-manager)

```sh
kubectl get certificates -A                # READY True?
kubectl get certificaterequests,orders,challenges -A
kubectl describe certificate -n kube-system wildcard
kubectl logs -n cert-manager deploy/cert-manager --tail=50
```

### DNS (ExternalDNS)

```sh
kubectl -n network logs deploy/external-dns --tail=20   # "All records are already up to date"
dig @10.0.1.30 <app>.home.lorenzolab.com                # the record in Technitium
```

### Storage (Longhorn)

```sh
kubectl -n longhorn-system get volumes.longhorn.io         # state, robustness (healthy/degraded)
kubectl -n longhorn-system get nodes.longhorn.io
kubectl -n longhorn-system get replicas.longhorn.io
kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80   # UI on http://localhost:8080
```

### Postgres (CloudNativePG)

```sh
kubectl get clusters.postgresql.cnpg.io -A          # STATUS "Cluster in healthy state"
kubectl get backups.postgresql.cnpg.io -A
kubectl get scheduledbackups.postgresql.cnpg.io -A
kubectl describe clusters.postgresql.cnpg.io -n <ns> <name>
kubectl logs -n <ns> <cluster>-1 -c plugin-barman-cloud --tail=50   # WAL archiving to R2
```

More in [Backups: Postgres](/kubernetes/backups-postgres).

## k9s

`k9s` shows the same things in a live TUI. Type `:` followed by a resource name or short name:

| Command | Shows |
| --- | --- |
| `:pods`, `:deploy`, `:svc`, `:pvc`, `:nodes` | the usual resources; `0` toggles all namespaces |
| `:ks`, `:hr`, `:gitrepositories`, `:ocirepositories` | Flux objects; READY and STATUS update live during a reconcile |
| `:events` | events, newest first |
| `:gateway`, `:httproute` | Gateway API |
| `:clusters.postgresql.cnpg.io` | CNPG clusters |

On a row: `d` describe, `l` logs, `s` shell, `y` YAML, `shift-f` port-forward, `ctrl-d` delete. `/` filters the list.

The k9s repo ships a [Flux plugin](https://github.com/derailed/k9s/blob/master/plugins/flux.yaml) that adds reconcile and suspend/resume shortcuts on Flux objects. To use it, copy its contents into `~/.config/k9s/plugins.yaml`.
