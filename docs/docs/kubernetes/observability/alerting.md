---
sidebar_position: 4
sidebar_label: Alerting
---

# Alerting

Prometheus evaluates the alerting rules and sends firing alerts to Alertmanager. Alertmanager groups them and sends `critical` and `warning` alerts to my phone through [Pushover](https://pushover.net), plus a second notification when they resolve. The always-firing `Watchdog` alert pings [healthchecks.io](https://healthchecks.io), which tells me when the alerting chain itself is down ([ADR 0005](https://github.com/lorenzorapetti/homelab/blob/main/docs/adr/0005-dead-mans-switch-on-healthchecks-io.md)).

Flux's alerts go the same way, as [migration open question 12](/kubernetes/migration#open-questions) settled: `FluxResourceNotReady` is a `PrometheusRule` on the Flux Operator's metrics, with no notification-controller `Provider` ([Monitoring Flux](/kubernetes/flux/monitoring)).

Everything is chart values in `kube-prometheus-stack/app/helmrelease.yaml` (`alertmanager.config`), plus the Secret `alertmanager-notifications`.

## Where alerts go

| Alert | Receiver | What happens |
| --- | --- | --- |
| `Watchdog` | `healthchecks` | Webhook POST to the healthchecks.io ping URL about every minute. No resolved notification |
| `severity="critical"` | `pushover-critical` | Pushover, priority **1** (high: sound even during quiet hours). Resolved: priority 0 |
| `severity="warning"` | `pushover-warning` | Pushover, priority **0** (normal). Resolved: priority -1 (quiet, no sound) |
| Any other or missing severity | `pushover-warning` | As `warning`, so a rule without a severity still reaches me |
| `severity="info"`, and `InfoInhibitor` (`severity="none"`) | `null` | Nothing. They stay visible in Alertmanager's UI |

The first matching route wins, in that order. Check where a given set of labels would go with `amtool config routes test` (see [Checks](#checks)).

## Grouping and timing

- **`group_by: [alertname, namespace]`.** One notification per alert name per namespace, listing every instance. Ten crash-looping pods in one namespace make one notification, not ten.
- **`group_wait: 30s`.** The first notification for a new group waits 30 seconds to gather alerts that fire together.
- **`group_interval: 5m`.** A group that changes (a new instance fires, one resolves) is notified again at most every 5 minutes.
- **`repeat_interval: 12h`.** An alert still firing is repeated every 12 hours.

### Inhibition

The chart's default inhibit rules are kept, because Helm merges `alertmanager.config` into the chart's default config and only `route` and `receivers` are overridden:

- A `critical` alert mutes the `warning` and `info` alerts with the same `alertname` and `namespace`. A `warning` mutes the matching `info`.
- `InfoInhibitor` mutes `info` alerts in its namespace. It fires whenever a namespace has an `info` alert and no `warning` or `critical` one: in steady state it fires only if an `info` alert does.

## The Secret

Alertmanager reads its credentials from files, so no secret value is in the Helm values or the generated `alertmanager.yaml`. `alertmanagerSpec.secrets: [alertmanager-notifications]` mounts the Secret at `/etc/alertmanager/secrets/alertmanager-notifications/`, and the receivers point at its keys with `user_key_file`, `token_file` and `url_file`.

`kube-prometheus-stack/app/alertmanager-notifications.sops.yaml`, Secret `alertmanager-notifications` in `observability`:

| Key | Value | Where it comes from |
| --- | --- | --- |
| `pushover-user-key` | My Pushover user key | The Pushover dashboard, top right |
| `pushover-token` | The API token of the `homelab` application | Pushover → **Create an Application/API Token** |
| `healthchecks-url` | `https://hc-ping.com/<uuid>` | The check's ping URL in healthchecks.io |

To set or rotate a value, with the YubiKey plugged in:

```sh
F=kubernetes/apps/observability/kube-prometheus-stack/app/alertmanager-notifications.sops.yaml
sops set $F '["stringData"]["pushover-user-key"]' '"<user key>"'
sops set $F '["stringData"]["pushover-token"]' '"<api token>"'
sops set $F '["stringData"]["healthchecks-url"]' '"https://hc-ping.com/<uuid>"'
# commit, push, let Flux reconcile
```

Alertmanager reads the files on every notification, so a changed Secret takes effect once the kubelet updates the mounted files (about a minute), with no restart.

## Watchdog and the dead man's switch

`Watchdog` fires for as long as Prometheus evaluates rules. Its route re-sends it to the `healthchecks` receiver every minute (`group_wait: 0s`, `group_interval: 1m`, `repeat_interval: 50s`; a repeat is only sent on a group-interval tick, so in practice the ping arrives every 1–2 minutes).

The check in healthchecks.io:

| Setting | Value |
| --- | --- |
| Name | `homelab alertmanager` |
| Schedule | Simple, **period 5 minutes, grace 5 minutes** |
| Integrations | Pushover, with the same Pushover account |

If no ping arrives for 10 minutes, healthchecks.io notifies me on Pushover, and again when pings resume. Possible causes: Prometheus or Alertmanager down, Prometheus not evaluating rules, the cluster down, or no internet at home.

Before planned work that stops Prometheus or Alertmanager (a cluster rebuild, Proxmox maintenance), **pause the check** in healthchecks.io; it resumes on the next ping. Silencing `Watchdog` in Alertmanager also stops the pings and trips the switch.

## Sending a test alert

From inside the Alertmanager pod, with `amtool`. The alert goes straight to Alertmanager, skipping Prometheus:

```sh
kubectl -n observability exec alertmanager-kube-prometheus-stack-0 -c alertmanager -- \
  amtool alert add --alertmanager.url=http://localhost:9093 \
  alertname=TestAlert severity=warning namespace=observability \
  --annotation='summary="Test alert, please ignore"' \
  --end="$(date -u -d '+3 minutes' +%Y-%m-%dT%H:%M:%SZ)"
```

About 30 seconds later (`group_wait`) Pushover shows `[FIRING:1] TestAlert`. When `--end` passes, the alert resolves, and the resolved notification follows at the next group interval, within 5 minutes. Use `severity=critical` to test the high-priority path. Don't send both severities with the same `alertname` at once: the critical one inhibits the warning one, which then never notifies. The annotation value needs its inner double quotes, or `amtool` warns that it fell back to the classic matcher parser.

To test the whole chain from Prometheus instead, apply a temporary rule that always fires, and delete it afterwards:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: test-alert
  namespace: observability
spec:
  groups:
    - name: test
      rules:
        - alert: TestAlert
          expr: vector(1)
          labels:
            severity: warning
          annotations:
            summary: Test alert from a PrometheusRule, please ignore
```

`kubectl apply -f` it, wait for the notification (rule evaluation, then `group_wait`), then `kubectl delete prometheusrule -n observability test-alert` and wait for the resolved one.

## Silencing an alert

For a known problem or planned work, silence it rather than changing rules. In the UI at `https://alertmanager.<domain>`: **New Silence**, add matchers (e.g. `alertname="KubePodCrashLooping"`, `namespace="media"`), set a duration and a comment.

Or with `amtool`:

```sh
kubectl -n observability exec alertmanager-kube-prometheus-stack-0 -c alertmanager -- \
  amtool silence add --alertmanager.url=http://localhost:9093 \
  --duration=2h --author=lorenzo --comment="Node maintenance" \
  alertname=KubePodCrashLooping namespace=media

# list and expire
kubectl -n observability exec alertmanager-kube-prometheus-stack-0 -c alertmanager -- \
  amtool silence query --alertmanager.url=http://localhost:9093
kubectl -n observability exec alertmanager-kube-prometheus-stack-0 -c alertmanager -- \
  amtool silence expire --alertmanager.url=http://localhost:9093 <id>
```

Silences are kept on Alertmanager's PVC, so they survive a restart. Never silence `Watchdog` (see above).

## Turning off a default rule

The chart's rules come in groups, each a `PrometheusRule`. When an alert can't apply to this cluster, turn it off in the chart values rather than silencing it forever:

- **A whole group**: `defaultRules.rules.<group>: false`, e.g. `defaultRules.rules.kubeProxy: false`. The group names are the keys under `defaultRules.rules` in the chart's `values.yaml` (`helm show values oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack --version <version>`).
- **One alert**: `defaultRules.disabled.<AlertName>: true`, e.g.

  ```yaml
  defaultRules:
    disabled:
      KubeCPUOvercommit: true
  ```

- **Change an alert's labels or annotations** instead of turning it off: `defaultRules.additionalRuleGroupLabels.<group>` or `customRules.<AlertName>` (`for`, `severity`).

Write down why next to the value. Today nothing is turned off by hand:

- **kube-proxy**: `kubeProxy.enabled: false` already drops its scrape target, and with it the `kubeProxy` rule group (the chart only renders it when the component is enabled). Cilium replaces kube-proxy.
- **etcd, scheduler, controller-manager**: scraped since [Control-plane metrics](/kubernetes/observability/control-plane-metrics), so their rules stay on.

## Checks

The config the operator generated, and where some labels would go:

```sh
kubectl -n observability get secret alertmanager-kube-prometheus-stack-generated \
  -o jsonpath='{.data.alertmanager\.yaml\.gz}' | base64 -d | gunzip
kubectl -n observability exec alertmanager-kube-prometheus-stack-0 -c alertmanager -- \
  amtool config routes test --config.file=/etc/alertmanager/config_out/alertmanager.env.yaml \
  alertname=Foo severity=critical
# pushover-critical
```

In steady state, only `Watchdog` fires (plus `InfoInhibitor` while an `info` alert fires):

```sh
kubectl -n observability exec alertmanager-kube-prometheus-stack-0 -c alertmanager -- \
  amtool alert query --alertmanager.url=http://localhost:9093
```

Notifications that failed show up in Alertmanager's own metrics, and in the chart's `AlertmanagerFailedToSendAlerts` alert, which Pushover can't deliver if Pushover is what's failing: check `alertmanager_notifications_failed_total{integration="pushover"}` in Prometheus, and the pod's log (`kubectl -n observability logs alertmanager-kube-prometheus-stack-0 -c alertmanager`). The healthchecks.io check shows the time of the last ping.

## Troubleshooting

- **No Pushover notification, Alertmanager log says `invalid token` or `user key is invalid`**: the Secret still holds a placeholder, or the token is for the wrong application. Fix it with `sops set` as above.
- **Alertmanager log says `no such file or directory` for a `*_file` path**: the Secret isn't mounted. Check that `alertmanager-notifications` exists in `observability` and is listed in `alertmanagerSpec.secrets`.
- **The healthchecks.io check is down but Alertmanager is fine**: look for a silence matching `Watchdog`, then `alertmanager_notifications_failed_total{integration="webhook"}`, then whether the pod can reach the internet.
