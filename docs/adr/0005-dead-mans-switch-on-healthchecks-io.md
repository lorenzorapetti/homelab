# The Watchdog alert pings healthchecks.io as a dead man's switch

Alerts reach the phone through Alertmanager and Pushover. That chain can only report problems while it is running itself: if Prometheus stops evaluating rules, Alertmanager is down, the cluster is gone, or the house loses power or internet, nothing is sent, and silence looks the same as "all is well".

kube-prometheus-stack ships `Watchdog`, an alert that always fires. Alertmanager sends it to a webhook receiver that POSTs to a [healthchecks.io](https://healthchecks.io) ping URL about once a minute (`repeat_interval: 50s`, `group_interval: 1m`). healthchecks.io notifies me through its own Pushover integration when the pings stop for longer than the check's period plus grace time.

This is the right trade-off because:

- **It covers the whole pipeline.** A ping only arrives if Prometheus evaluates rules, Alertmanager receives the alert and routes it, and the cluster can reach the internet. Any of these failing is noticed.
- **The watcher is outside the homelab.** It doesn't share power, network or hardware with what it watches.
- **It costs nothing and runs nothing new.** The free tier covers it, and the cluster gains only a receiver and a URL in an existing Secret.

## Considered options

- **No external switch.** Simplest, but an outage of the alerting chain, or of the whole site, would go unnoticed until I happened to look.
- **A second Alertmanager or Prometheus watching the first, inside the homelab.** It would share the same failure modes (power, internet, Proxmox hosts), so it can't report the outages that matter most.
- **Self-hosted healthchecks or Uptime Kuma on a VPS.** It works the same way, but adds a machine to run, patch and watch.
- **Commercial dead man's switch services** (Dead Man's Snitch, Cronitor, Better Stack). Equivalent in function, with smaller free tiers or none.

## Consequences

- The ping URL is a secret: anyone who has it can keep the check green. It lives in the SOPS Secret `alertmanager-notifications` and Alertmanager reads it with `url_file`, so it never appears in the Helm values or the generated Alertmanager config.
- An outage notification comes from healthchecks.io, not from Alertmanager, so it has a different title and links to healthchecks.io.
- A maintenance window that stops Prometheus or Alertmanager (a cluster rebuild, a long Proxmox outage) triggers the switch. Pause the check in healthchecks.io beforehand.
- Silencing `Watchdog` in Alertmanager stops the pings too, and trips the switch.
