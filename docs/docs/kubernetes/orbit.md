---
sidebar_position: 5.95
sidebar_label: Orbit
---

# Orbit

[Orbit](https://github.com/coollabsio/orbit) (by coolLabs) is the homelab's project board, at `https://board.<domain>`. Upstream docs: [`docs/`](https://github.com/coollabsio/orbit/tree/main/docs), mainly `self-hosting-postgres.md` and `operations.md`.

## As built

Plain manifests, no chart: `ghcr.io/coollabsio/orbit:0.4.1`, in namespace `orbit`. Files: `kubernetes/apps/orbit/orbit/`.

- **One binary, one pod.** `serve` runs the web app, background jobs and the scheduler, and runs the database migrations at every start. No worker, no Redis. The Deployment uses `Recreate`: the PVC is ReadWriteOnce, and some migrations want every server stopped first.
- **Two Flux Kustomizations**, like Forgejo: `orbit-db` (a one-instance CNPG `Cluster`, Postgres 18.7, 5Gi on Longhorn, archived to `s3://<bucket>/orbit/orbit-db/` on R2, [Backups: Postgres](/kubernetes/backups-postgres)), then `orbit`, which waits for it.
- **The database** must use the builtin locale provider with `C.UTF-8`, or Orbit refuses to start. `initdb` in `db/cluster.yaml` sets it. Orbit connects with CNPG's `uri` from Secret `orbit-db-app` (`ORBIT_DATABASE_URL`), with 10 connections per pool (two pools plus a lock connection).
- **Data**: PVC `orbit` (5Gi, Longhorn) at `/var/lib/orbit`, which holds the attachments. VolSync backs it up every night as uid 65532 ([Backups: volumes](/kubernetes/backups-volsync)). Orbit's own backup directory, `/var/backups/orbit`, is an `emptyDir`: CNPG and VolSync are the real backups. More than one replica would need S3 for attachments.
- **Settings** are `ORBIT_*` env vars in the Deployment. Secret ones come from the SOPS Secret `orbit-secrets` through `envFrom`. **Orbit refuses to start on an `ORBIT_*` variable it doesn't know**, so check a new setting against the pinned version's docs. That's also why the pod sets `enableServiceLinks: false`: the Services `orbit-db-rw`/`-ro`/`-r` would otherwise inject `ORBIT_DB_RO_PORT` and friends.
- **`ORBIT_APP_KEY`** (in `orbit-secrets`) encrypts the secrets Orbit saves (2FA, integrations) and its backups. Never rotate or lose it.
- **Proxies**: Orbit trusts `X-Forwarded-*` only from `ORBIT_TRUSTED_PROXIES`: the pod CIDR `10.244.0.0/16`, where Cilium's Envoy sends from, plus loopback for the image's healthcheck. The probes run `/orbit healthcheck` (exec), because a kubelet `httpGet` would come from the node's address.
- **Mail** through Resend (`smtp.resend.com:587`, STARTTLS, user `resend`), like authentik and Forgejo. The API key and From address are `ORBIT_SMTP_PASSWORD` and `ORBIT_SMTP_FROM` in `orbit-secrets`. Incoming mail (`ORBIT_MAIL_*`) is off.

### Route

The `HTTPRoute` `orbit` on the Shared Gateway's `https` listener, no forward auth (Orbit has its own login). ExternalDNS publishes `board.<domain>` to Home DNS from it.

### Login

- **authentik, OIDC** (`ORBIT_OIDC_*`). The provider and application come from the blueprint `kubernetes/apps/auth/authentik/app/blueprints/orbit.yaml`, and only `authentik Admins` may use it. Callback: `/api/v1/auth/providers/oidc/callback`.
- **`email_verified`**: Orbit links a login to an existing account only when the claim is true, and authentik's managed `email` mapping sends false. The blueprint brings its own email mapping, `Orbit: email (verified)`, which sends true.
- **Accounts** are created on first login through authentik (`ORBIT_OIDC_PROVISION`). Registration is closed (`ORBIT_OPEN_REGISTRATION=false`).
- **The client secret** is in two SOPS Secrets that must hold the same value: `ORBIT_OIDC_CLIENT_SECRET` in `orbit-secrets` (`orbit`) and in `authentik-orbit-oidc` (`auth`). authentik's worker reads it at start, so restart it after changing it.
- **Root account**: the only one that can open Orbit's Admin. It is created from a one-time setup URL on first start (below), with a password. It's also the break-glass login when authentik is down.

## First start

1. Commit, push, `just bootstrap::reconcile`. `orbit-db`, then `orbit` should go Ready. Restart authentik's worker so it picks up `authentik-orbit-oidc`: `kubectl -n auth rollout restart deployment authentik-worker`.
2. Get the setup URL: `kubectl -n orbit logs deploy/orbit | grep 'setup URL'`. Lost it: `kubectl -n orbit exec deploy/orbit -- /orbit setup-token rotate`.
3. Open it and create the root account **with the same email as your authentik user**, so that **Sign in with authentik** later lands on the same account. Then create the first workspace and project.
4. Log out and log in again with **Sign in with authentik** to check OIDC.

## Upgrades

Renovate bumps the image tag. Read the release notes first: an older image can't open a newer schema (no rollback without restoring `orbit-db`), and a release can add or rename `ORBIT_*` settings.

## Monitoring

- **Metrics**: Orbit's `/metrics` on port 9090 (`ORBIT_METRICS_LISTEN`). It has no auth, so it stays off the HTTPRoute. `app/servicemonitor.yaml`, every 60s.
- **No dashboard or Orbit alerts.** The stack's generic rules cover crash loops and a pod that isn't ready, `CNPG*` cover the database and `VolSyncVolumeOutOfSync` the attachments backup.
- **Logs**: in Loki under `{namespace="orbit", app="orbit"}`.
