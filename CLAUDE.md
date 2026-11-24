# homelab

## IP addresses

Whenever a change gives anything a new or changed IP (a service on a LoadBalancer IP, a VIP, a host, a VM, a subnet), record it in the same change in both:

- the `Network` page in `kubernetes/apps/glance/glance/app/glance.yml` (the homelab inventory; NetBox is gone), and
- the network map in `docs/docs/kubernetes/intro.md`.

## Agent skills

### Issue tracker

Issues are tracked in GitHub Issues for `lorenzorapetti/homelab`, managed with the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Uses the five default triage labels: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `GLOSSARY.md` at the repo root and ADRs in `docs/adr/`. See `docs/agents/domain.md`.
