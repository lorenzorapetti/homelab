# Cluster bootstrap after `just talos::create`. Recipes run in bootstrap/.
# Docs: docs/docs/kubernetes/getting-started/bootstrap.md

export KUBECONFIG := justfile_directory() / "kubeconfig"

[doc("Secrets, Gateway API CRDs, Cilium + Flux. The YubiKey must be plugged in")]
apps: wait-for-nodes secrets crds helmfile

[doc("Wait until the nodes have registered (they stay NotReady until Cilium is up)")]
wait-for-nodes:
    until [[ -n "$(kubectl get nodes -o name --request-timeout=10s 2>/dev/null)" ]]; do sleep 5; done

[doc("flux-system namespace + Flux's age key and Git pull secret (YubiKey: PIN + touch)")]
secrets: wait-for-nodes
    kubectl create namespace flux-system --dry-run=client -o yaml | kubectl apply --server-side -f -
    sops decrypt sops-age.sops.yaml | kubectl apply --server-side -f -
    sops decrypt github-deploy-key.sops.yaml | kubectl apply --server-side -f -

[doc("Install the Gateway API v1.6.3 CRDs (experimental channel); Cilium needs them before it starts")]
crds: wait-for-nodes
    kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.3/experimental-install.yaml

[doc("Show what `helmfile` would change (helm diff)")]
diff:
    helmfile --file helmfile/apps.yaml diff

[doc("Install or upgrade Cilium, the Flux Operator and the FluxInstance; a no-op when nothing changed")]
helmfile: wait-for-nodes
    helmfile --file helmfile/apps.yaml apply --hide-notes --skip-diff-on-install

[doc("Force Flux to pull the repo now")]
reconcile:
    flux --namespace flux-system reconcile kustomization flux-system --with-source
