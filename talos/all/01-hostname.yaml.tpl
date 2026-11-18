# topf doesn't set the Talos hostname from `host` on its own.
apiVersion: v1alpha1
kind: HostnameConfig
auto: "off"
hostname: {{ .Node.Host }}
