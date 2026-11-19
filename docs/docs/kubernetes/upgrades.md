---
sidebar_position: 8
sidebar_label: Upgrades
---

# Upgrading the cluster

How to upgrade Talos, Kubernetes, Cilium, Flux, the Gateway API CRDs, the Helm releases and the CLI tools. Each one is pinned in exactly one file, and a `just` recipe rolls it out:

| What | Pinned in | Roll out with |
| --- | --- | --- |
| Talos (OS + system extensions) | `talosVersion` in `talos/topf.yaml`, `talos/schematic.yaml` | `just talos::upgrade` |
| Kubernetes | `kubernetesVersion` in `talos/topf.yaml` | `just talos::upgrade-k8s` |
| Cilium | `ref.tag` in `kubernetes/apps/kube-system/cilium/app/ocirepository.yaml` | push, then `just bootstrap::reconcile` |
| Flux Operator, `flux-instance` chart | `ref.tag` in `kubernetes/apps/flux-system/{flux-operator,flux-instance}/app/ocirepository.yaml` (keep both equal) | push, then `just bootstrap::reconcile` |
| Flux itself | `instance.distribution.version` (`2.10.x`) in `kubernetes/apps/flux-system/flux-instance/app/helmrelease.yaml` | the operator picks the newest `2.10.x`; for a minor, bump it and push ([Flux](#flux)) |
| Gateway API CRDs | `ref.tag` in `kubernetes/apps/kube-system/gateway-api-crds/ks.yaml` (`just bootstrap::crds` reads it too) | push, then `just bootstrap::reconcile` |
| CLI tools (`talosctl`, `kubectl`, `helm`, `helmfile`, `cilium`, `flux`, …) | `devenv.lock` (`topf`: `devenv.nix`) | `devenv update` |

Cilium, Flux and the Gateway API CRDs are Flux apps (steps 1–3 of the [migration](/kubernetes/migration)). Their versions and values live only in `kubernetes/apps/`, and the bootstrap reads them from there ([one source of truth](/kubernetes/getting-started/bootstrap#one-source-of-truth-for-values)). helm-controller (or kustomize-controller, for the CRDs) does the upgrade once the commit is pushed. `just bootstrap::reconcile` only makes Flux pull right away instead of at its next poll. Don't run `just bootstrap::helmfile` or `just bootstrap::crds` on the running cluster ([why](/kubernetes/getting-started/bootstrap#just-bootstrapapps-after-a-takeover)). Once Renovate is enabled, it opens the version PRs. Talos and Kubernetes stay manual.

:::warning Upgrades don't go through Terraform

`talos_version` and `talos_schematic_id` in `infrastructure/variables.auto.tfvars` only pick the disk image that **new** VMs boot from. The running nodes have Talos installed on their system disk, and in-place upgrades go through `topf`. **Leave both values alone when you upgrade.** Leaving them at the old version is harmless: a VM created from an older image installs the version in `topf.yaml` when `topf apply` first configures it (the installer image comes from `talosVersion` and the schematic, see [Install Talos](/kubernetes/getting-started/install-talos#topfyaml)).

Both values are part of the image's file name, and the VM's system disk is created from that file. Without a guard, changing either one would make `terraform plan` replace **all three VMs**, Longhorn disks included:

```
# proxmox_virtual_environment_vm.talos["talos-1"] must be replaced
          ~ file_id = "local:iso/talos-v1.14.5-88d1f7a5-nocloud-amd64.img" -> (known after apply) # forces replacement
```

So `infrastructure/vms.tf` has `lifecycle { ignore_changes = [disk[0].file_id] }`. With it, the same change plans only `proxmox_download_file.talos must be replaced` (`1 to add, 0 to change, 1 to destroy`): the new image is downloaded to Proxmox and the old one deleted, and the VMs are untouched. To rebuild a VM from the new image on purpose, replace it explicitly: `just tf::apply -replace='proxmox_virtual_environment_vm.talos["talos-1"]'`.

:::

## Rules for every upgrade

- **One minor version at a time, from the latest patch.** Talos only tests config migration "between adjacent minor releases", so "always upgrade to the latest patch release of all intermediate minor releases" ([Talos upgrade guide](https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/lifecycle-management/upgrading-talos.md#supported-upgrade-paths)). Cilium: "The only tested rollback and upgrade path is between consecutive minor releases", and "Always update to the latest patch release of your current version before attempting an upgrade" ([upgrade warning](https://github.com/cilium/cilium/blob/v1.20.5/Documentation/operations/upgrade-warning.rst)). Kubernetes' [version skew policy](https://kubernetes.io/releases/version-skew-policy/) moves the control plane one minor version at a time too.
- **Check compatibility before a Kubernetes minor upgrade.** Two tables decide which Kubernetes version you can run:
  - the [Talos support matrix](https://docs.siderolabs.com/talos/v1.14/getting-started/support-matrix.md): Talos 1.14 supports Kubernetes 1.33–1.37, Talos 1.13 supports 1.31–1.36.
  - [Cilium's Kubernetes compatibility page](https://github.com/cilium/cilium/blob/v1.20.5/Documentation/network/kubernetes/compatibility.rst) for the Cilium version you run: Cilium 1.20 e2e-tests 1.33–1.36. The cluster already runs 1.37 on it ([Bootstrap the cluster](/kubernetes/getting-started/bootstrap#cilium-networking)), so don't go further until Cilium catches up.
  - the "Kubernetes compatibility" table in the [Flux release notes](https://github.com/fluxcd/flux2/releases) for the Flux minor you run: Flux 2.10.0 supports 1.35–1.37, and "the Flux project offers support only for the latest three minor versions of Kubernetes".
- **So the order is Talos, then Cilium, then Kubernetes.** A newer Talos supports the newer Kubernetes, and Cilium has to support it before the control plane moves. Patch upgrades of any one of them can happen on their own.
- **Read the release notes** of the target version: [Talos releases](https://github.com/siderolabs/talos/releases) (and the "Before upgrade to …" section of its upgrade guide), [topf releases](https://github.com/postfinance/topf/releases) for a new Talos minor (topf is built against a specific Talos version), the upgrade notes at the end of [Cilium's upgrade guide](https://docs.cilium.io/en/stable/operations/upgrade/), and the [Kubernetes changelog](https://kubernetes.io/releases/).
- **Start from a healthy cluster**, and check again after each step:

  ```bash
  talosctl --nodes 10.0.11.1 health
  kubectl get nodes
  cilium status --wait
  ```

- **Take an etcd snapshot before a minor upgrade:** `talosctl --nodes 10.0.11.1 etcd snapshot etcd.snapshot`. The file holds every Secret in the cluster in plain text, so keep it out of Git and delete it once the upgrade is done.
- **Run everything inside `devenv shell`.** It sets `TALOSCONFIG` and `KUBECONFIG`.

## Talos

Use this for a new Talos version or for a changed `schematic.yaml` (adding or removing a system extension). Both change the installer image, `factory.talos.dev/nocloud-installer/<schematicId>:v<talosVersion>`, which topf derives from `topf.yaml`.

1. **Bump `talosVersion`** in `talos/topf.yaml`, or edit `talos/schematic.yaml`. `schematicId: "@schematic.yaml"` recomputes the ID locally, so there is nothing else to edit. For a new minor version, also update `talosctl` (see [CLI tools](#cli-tools)): Talos recommends using the `talosctl` "that matches the current running version of the cluster".
2. **Preview:**

   ```bash
   just talos::upgrade --dry-run
   ```

   topf compares the schematic and version of the installer image with each node and lists only the nodes that differ.
3. **Upgrade:**

   ```bash
   just talos::upgrade
   ```

   It asks before each node. Control-plane nodes always go **one at a time**. On Talos ≥ 1.13, per node, topf pre-pulls the installer image, installs it, then cordons and drains the node (5-minute timeout), reboots it with kexec, waits until it has been Ready for 30 seconds, and uncordons it ([topf upgrade](https://github.com/postfinance/topf/blob/main/docs/commands/upgrade.md#behavior)). Talos itself refuses an upgrade that would cost etcd quorum. If a drain fails, topf stops and leaves that node cordoned, with the new image installed but not rebooted. Per topf's docs, "the node must be uncordoned and rebooted manually to recover": fix whatever blocks the eviction (usually a PodDisruptionBudget), then `kubectl uncordon <node>` and `talosctl --nodes <ip> reboot`. Then rerun `just talos::upgrade`; it skips the nodes that already run the target version. `--delete-if-eviction-fails` makes topf fall back to deleting the pods (bypassing PDBs) instead of giving up.
4. **Check:** `talosctl version --short` shows the new tag on every node, `just talos::diff` shows no changes, and the health checks above pass.

A Talos upgrade doesn't change the Kubernetes version ([Talos upgrade guide](https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/lifecycle-management/upgrading-talos.md)). Longhorn data survives: Talos ≥ 1.8 preserves `/var/lib/longhorn`, and the Longhorn volume is on its own disk anyway ([Storage: Longhorn](/kubernetes/storage-longhorn#talos-upgrades)).

**Rollback.** Talos keeps the previous version (A/B images). If an upgraded node doesn't boot, Talos rolls back by itself. If it boots but workloads misbehave, run `talosctl --nodes <ip> rollback`, then revert `talosVersion` in `topf.yaml` so the next `just talos::upgrade` doesn't upgrade the node again.

## Kubernetes

1. **Check compatibility** with the running Talos and Cilium (see the [rules](#rules-for-every-upgrade)). For a minor version, also check for removed APIs in the [deprecation guide](https://kubernetes.io/docs/reference/using-api/deprecation-guide/).
2. **Bump `kubernetesVersion`** in `talos/topf.yaml`.
3. **Preview:**

   ```bash
   just talos::upgrade-k8s --dry-run
   ```

   It lists the resources whose APIs are deprecated in the target version, plus every component and bootstrap manifest it would update.
4. **Upgrade:**

   ```bash
   just talos::upgrade-k8s
   ```

   This runs `talosctl upgrade-k8s --to <kubernetesVersion>`. It pre-pulls the images, updates kube-apiserver, kube-controller-manager and kube-scheduler one node at a time, updates the kubelet on every node, then re-applies the bootstrap manifests (CoreDNS) and prunes what's no longer needed ([Talos: upgrading Kubernetes](https://docs.siderolabs.com/kubernetes-guides/advanced-guides/upgrading-kubernetes.md)). kube-proxy is disabled, so there's no kube-proxy DaemonSet to update. "If the command fails for any reason, it can be safely restarted to continue the upgrade process from the moment of the failure."
5. **Check:** `kubectl get nodes` shows the new version everywhere, the health checks pass, and `cilium status` is still OK.

**Don't run `just talos::apply` between steps 2 and 4.** `topf apply` would also roll out the new version, but it "does **not** validate version compatibility, API version skew, or component readiness" ([topf: Kubernetes upgrade](https://github.com/postfinance/topf/blob/main/docs/kubernetes-upgrade.md)). topf's docs run `upgrade-k8s` first and bump `topf.yaml` afterwards. The recipe reads the version from `topf.yaml`, so here the bump comes first and the commit records the version actually running.

After a minor upgrade, also bump `kubectl` ([CLI tools](#cli-tools)). The Kubernetes [version skew policy](https://kubernetes.io/releases/version-skew-policy/#kubectl) supports kubectl within one minor version of the API server.

## Cilium

Cilium is a Flux app: the `cilium` HelmRelease in `kubernetes/apps/kube-system/cilium/app/`.

1. **Read the upgrade notes** for the target minor version, at the end of [Cilium's upgrade guide](https://docs.cilium.io/en/stable/operations/upgrade/). They list required changes and renamed or removed values. Compare them with `spec.values` in `kubernetes/apps/kube-system/cilium/app/helmrelease.yaml`.
2. **Check the Gateway API version** the target Cilium documents ([Cilium Gateway API docs](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api/)). If it's newer, upgrade the [CRDs](#gateway-api-crds) first.
3. **Run the pre-flight check** for a minor upgrade. Cilium's guide calls it "Required": it pre-pulls the new image on every node and validates the existing network policies against the new version. With kube-proxy replacement, it needs the API server address:

   ```bash
   helm install cilium-preflight oci://quay.io/cilium/charts/cilium --version <new> \
     --namespace kube-system \
     --set preflight.enabled=true --set agent=false --set operator.enabled=false \
     --set k8sServiceHost=localhost --set k8sServicePort=7445
   kubectl -n kube-system get daemonset | sed -n '1p;/cilium/p'     # cilium-pre-flight-check READY = cilium READY
   kubectl -n kube-system get deployment cilium-pre-flight-check    # READY 1/1
   helm -n kube-system delete cilium-preflight
   ```

   If the deployment stays at `0/1`, a network policy fails validation: see the CNP validation section of the [upgrade guide](https://docs.cilium.io/en/stable/operations/upgrade/) before going on ([pre-flight check source](https://github.com/cilium/cilium/blob/v1.20.5/Documentation/operations/upgrade.rst)).
4. **Bump `ref.tag`** in `kubernetes/apps/kube-system/cilium/app/ocirepository.yaml`. Change the values in the HelmRelease in the same commit if the upgrade notes require it. **Don't change `upgradeCompatibility`.** It stays at `"1.20"`, the version this cluster was first installed with: "To minimize datapath disruption during the upgrade, the `upgradeCompatibility` option should be set to the initial Cilium version which was installed in this cluster."
5. **Push and reconcile:**

   ```bash
   git push
   just bootstrap::reconcile
   flux get hr -n kube-system cilium --watch   # until Ready on the new version
   ```

   helm-controller always renders from the full `spec.values`, so this never relies on Helm's `--reuse-values`, which Cilium warns against for minor upgrades. The `cilium` Kustomization health-checks the HelmRelease, and the HelmRelease waits for the rollout. A failed upgrade is retried twice (the defaults the FluxInstance injects, [Flux page](/kubernetes/flux/intro#the-fluxinstance)).
6. **Check:** `cilium status --wait`, and every agent reports the new version. After a minor upgrade, also run the connectivity test. On Talos it needs the privileged label ([Checking Cilium](/kubernetes/getting-started/bootstrap#checking-cilium)):

   ```bash
   cilium connectivity test --namespace-labels pod-security.kubernetes.io/enforce=privileged
   kubectl get ns -o name | grep cilium-test | xargs kubectl delete
   ```

**Rollback:** `git revert` the bump and push. helm-controller then upgrades back to the old chart. A `helm rollback` by hand doesn't stick, because helm-controller sees the release changed outside Flux and upgrades it again to what Git says. Only roll back one minor version, and check the upgrade notes if you've already started using a feature of the new version.

**With Renovate enabled**, it bumps the chart tag in `kubernetes/apps/kube-system/cilium/app/` and the merge rolls it out. The pre-flight check, the upgrade notes and the "one minor at a time" rule still apply, so don't merge a minor-version Renovate PR without doing steps 1–3 first. Patch PRs can be merged directly.

## Flux

Flux manages itself ([Flux manages itself](/kubernetes/flux/intro#flux-manages-itself)), so its three version pins are all in `kubernetes/apps/flux-system/`:

- **The Flux Operator chart**, `ref.tag` in `flux-operator/app/ocirepository.yaml`.
- **The `flux-instance` chart**, `ref.tag` in `flux-instance/app/ocirepository.yaml`. Both charts are released together with the operator, so keep the two tags equal.
- **The Flux distribution**, `instance.distribution.version: "2.10.x"` in `flux-instance/app/helmrelease.yaml`. It "must be a valid semver range or an exact version" ([FluxInstance docs](https://fluxoperator.dev/docs/crd/fluxinstance/)), and the range pins the minor, so a minor upgrade is always a deliberate commit.

Every change here means helm-controller upgrades the chart that runs helm-controller. A forced upgrade with unchanged values is safe and rolls nothing. A real version change hasn't been tried yet, so read [Flux upgrading itself](/kubernetes/getting-started/bootstrap#flux-upgrading-itself) first, and check `helm -n flux-system history flux-instance` afterwards.

To see what's running:

```bash
kubectl -n flux-system get fluxinstance flux   # REVISION: v2.10.0@sha256:…
kubectl -n flux-system get fluxreport flux -o yaml | yq '.spec.distribution, .spec.operator'
flux version                                   # CLI, distribution and each controller
```

### Patch releases

Nothing to commit for Flux itself: the operator resolves `2.10.x` to the newest matching release it knows about. Version selection "is constrained to Flux minor versions embedded in the running operator image", and the operator reconciles the instance every hour by default (`fluxcd.controlplane.io/reconcileEvery`, [FluxInstance docs](https://fluxoperator.dev/docs/crd/fluxinstance/)). **Unverified:** how soon a new 2.10 patch appears; 2.10.0 is still the only one (2026-11-18). If it doesn't show up, upgrade the operator (below) and check again.

### Operator upgrades

Do this first for every Flux minor upgrade, and on its own whenever a new operator release comes out. The Flux docs: "first update the operator to the latest version, then update the `FluxInstance` resource to specify the latest Flux minor version" ([Upgrade with Flux Operator](https://fluxcd.io/flux/installation/upgrade/)).

1. **Read the [operator release notes](https://github.com/controlplaneio-fluxcd/flux-operator/releases).** They say which Flux minors a release adds (0.62.0: "Add Flux 2.10 compatibility"). There is no published compatibility matrix.
2. **Bump `ref.tag` of both `flux-operator` and `flux-instance`** in their `ocirepository.yaml`, in one commit.
3. **Push and reconcile:**

   ```bash
   git push
   just bootstrap::reconcile
   flux get hr -n flux-system --watch   # both Ready on the new chart version
   ```

4. **Check:** the `fluxreport` shows the new operator version, `fluxinstance flux` is still Ready, and the last revision in `helm -n flux-system history flux-operator` and `… flux-instance` is `deployed`, not `pending-upgrade`.

### Minor releases (e.g. 2.10 → 2.11)

1. **Read the [Flux release notes](https://github.com/fluxcd/flux2/releases)** for the target minor: breaking changes, removed API versions, and its Kubernetes compatibility table. Flux doesn't require going one minor at a time ("Users can upgrade from any `v2.x` release to any other `v2.x` release (the latest patch version)", [Flux releases](https://fluxcd.io/flux/releases/)), but I still go one minor at a time so each set of release notes is small.
2. **Upgrade the operator** to a release that supports the new minor ([above](#operator-upgrades)).
3. **Update the `flux` CLI** with `devenv update` (see [CLI tools](#cli-tools)). "The `flux` command-line tool is supported within one minor version (older or newer) of Flux" ([Flux releases](https://fluxcd.io/flux/releases/)), so it can run ahead of the cluster for one step.
4. **Migrate the manifests in Git** to the new API versions, using the new CLI:

   ```bash
   flux migrate -f kubernetes/apps --dry-run   # show what would change
   flux migrate -f kubernetes/apps             # rewrite; review the diff
   ```

   This "migrates the Flux custom resources defined in the manifests located in the specified path. Spec fields that do not exist in the latest API version are removed from the manifests" ([`flux migrate`](https://fluxcd.io/flux/cmd/flux_migrate/)), so read the diff before committing. `--version 2.11` targets a minor other than the CLI's. The objects already stored in etcd are migrated by the operator: `.spec.migrateResources` defaults to `true`, and "the migration runs after the Flux distribution is upgraded from a minor version to another and only when a new API version is introduced" ([FluxInstance docs](https://fluxoperator.dev/docs/crd/fluxinstance/)).
5. **Bump `instance.distribution.version`** to `"2.11.x"` in `kubernetes/apps/flux-system/flux-instance/app/helmrelease.yaml`, in the same commit as the migrated manifests. Push it, then run `just bootstrap::reconcile`. This is the commit where helm-controller replaces itself mid-upgrade ([Flux upgrading itself](/kubernetes/getting-started/bootstrap#flux-upgrading-itself)).
6. **Check:**

   ```bash
   kubectl -n flux-system get fluxinstance flux   # Ready, REVISION v2.11.x
   flux version
   flux get kustomizations -A
   flux get helmreleases -A
   helm -n flux-system history flux-instance --max 2   # last revision deployed, not pending-upgrade
   ```

**Rollback:** the docs don't cover lowering `distribution.version`, and objects already migrated to a new API version may not be readable by the older controllers. Treat a Flux minor upgrade as one-way: fix forward, and take an etcd snapshot first ([Rules](#rules-for-every-upgrade)). A bad operator upgrade on its own can be rolled back by reverting the tag bump in Git and pushing. A `helm rollback` by hand would be upgraded again by helm-controller.

**With Renovate enabled**, it bumps the two charts' `OCIRepository` tags. The order above still applies: merge the operator bump before the Flux minor bump.

## Gateway API CRDs

1. Check that the target version is the one Cilium documents (see the Cilium section above). Cilium's Gateway API controller is only tested against that version.
2. Change `ref.tag` of the `GitRepository` in `kubernetes/apps/kube-system/gateway-api-crds/ks.yaml`. `just bootstrap::crds` reads the same tag, so a fresh cluster installs the new version too.
3. Push, then `just bootstrap::reconcile`. kustomize-controller server-side applies the new CRDs in place, and `flux get kustomizations -n kube-system gateway-api-crds` shows the new tag.

Don't run `just bootstrap::crds` on the running cluster: kustomize-controller owns the objects, and the plain `kubectl apply --server-side` conflicts with it on the `safe-upgrades` policy ([takeover](/kubernetes/getting-started/bootstrap#taking-over-the-kubectl-applied-crds)).

The bundle installs the `safe-upgrades.gateway.networking.k8s.io` ValidatingAdmissionPolicy. It blocks two mistakes: installing CRDs older than v1.5, and installing experimental CRDs over standard ones. If the Kustomization fails with one of those messages, check the tag and the `path` (`config/crd/experimental`); don't delete the policy. A version is never removed from the cluster by Flux: every object carries `kustomize.toolkit.fluxcd.io/prune: disabled` ([why](/kubernetes/getting-started/bootstrap#the-crds-as-a-flux-app)).

## Helm releases

The bootstrap helmfile (`bootstrap/helmfile/apps.yaml`: `cilium`, `flux-operator`, `flux-instance`) only installs a fresh cluster. It has no versions of its own: it reads them from the Flux manifests, so bumping an app's `OCIRepository` tag also changes what the next bootstrap installs. On the running cluster, Flux owns all three releases, so use `just bootstrap::diff` only to compare ([expected differences](/kubernetes/getting-started/bootstrap#just-bootstrapapps-after-a-takeover)).

Apps under `kubernetes/apps/` aren't upgraded with Helm by hand: their `HelmRelease`/`OCIRepository` versions are bumped in Git (by Renovate, once `"enabled": false` is removed from `renovate.json` after the rebuild), and helm-controller does the upgrade.

## CLI tools

Everything except `topf` comes from nixpkgs through `devenv.lock`, which follows `cachix/devenv-nixpkgs/rolling`.

1. `devenv update` bumps the lock (nixpkgs and devenv), so `talosctl`, `kubectl`, `helm`, `helm-diff`, `helmfile`, `cilium`, `flux`, `sops`, `terraform` and the rest all move together.
2. `devenv test` runs `enterTest`, which prints every tool's version.
3. Compare with the cluster: `talosctl version --short` (client = server minor version), `kubectl version` (within one minor of the server), `flux version` (within one minor of the Flux controllers).

nixpkgs ships the newest `talosctl`, so after `devenv update` it can be a minor version ahead of the cluster. Talos's FAQ recommends "the version that matches the current running version of the cluster", so either do the Talos upgrade next, or hold `talosctl` back by pinning it in `devenv.nix` the way `topf` is pinned.

`topf` is pinned in `devenv.nix`. To bump it, change `version`, then refresh `hash` with `nix store prefetch-file https://github.com/postfinance/topf/releases/download/v<version>/topf_linux_amd64.tar.gz`. Check its release notes for the Talos version it's built against before a Talos minor upgrade.
