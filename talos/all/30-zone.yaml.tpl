# One zone per Proxmox host, so anything zone-aware (Longhorn replicas, pod
# topology spread) keeps its copies on different physical machines.
# The host comes from data.proxmoxHost in topf.yaml: keep it in sync with
# proxmox_node in infrastructure/variables.auto.tfvars when a VM migrates.
apiVersion: v1alpha1
kind: KubeNodeConfig
labels:
  topology.kubernetes.io/zone: {{ .Node.Data.proxmoxHost }}
