# Cluster bootstrap after `just talos::create`. Recipes run in bootstrap/.
# Docs: docs/docs/kubernetes/getting-started/bootstrap.md
#
# The Flux bootstrap adds `secrets`, `apps` and `reconcile` here.

export KUBECONFIG := justfile_directory() / "kubeconfig"

[doc("Wait until the nodes have registered (they stay NotReady until Cilium is up)")]
wait-for-nodes:
    until [[ -n "$(kubectl get nodes -o name --request-timeout=10s 2>/dev/null)" ]]; do sleep 5; done

[doc("Install the Gateway API v1.6.3 CRDs (experimental channel); Cilium needs them before it starts")]
crds: wait-for-nodes
    kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.3/experimental-install.yaml

[doc("Show what `cilium` would change (helm diff)")]
diff:
    helmfile --file helmfile/apps.yaml diff

[doc("Install or upgrade Cilium; a no-op when nothing changed")]
cilium: wait-for-nodes
    helmfile --file helmfile/apps.yaml apply --hide-notes --skip-diff-on-install
