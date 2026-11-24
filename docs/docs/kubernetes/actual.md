---
sidebar_position: 5.97
sidebar_label: Actual Budget
---

# Actual Budget

[Actual Budget](https://actualbudget.org) is the homelab's budgeting app, at `https://budget.<domain>`. Upstream docs: [actualbudget.org/docs](https://actualbudget.org/docs/), mainly *Config* and *OpenID*.

## As built

Plain manifests, no chart: `docker.io/actualbudget/actual-server:26.11.0`, in namespace `actual`. Files: `kubernetes/apps/actual/actual/`.

- **One pod, no database server.** The sync server serves the web app and keeps everything in SQLite files under `/data`: `server-files/account.sqlite` (users, sessions, the OpenID config) and `user-files/` (the budgets). The Deployment uses `Recreate`: the PVC is ReadWriteOnce and SQLite wants one writer.
- **Data**: PVC `actual` (2Gi, Longhorn) at `/data`. VolSync backs it up every night as uid 1001 ([Backups: volumes](/kubernetes/backups-volsync)).
- **User**: the image has no `USER`, so the pod sets uid/gid 1001, the image's `actual` user.
- **Settings** are `ACTUAL_*` env vars in the Deployment. The one secret, `ACTUAL_OPENID_CLIENT_SECRET`, comes from the SOPS Secret `actual-secrets` through `envFrom`.
- **Proxies**: `ACTUAL_TRUSTED_PROXIES` is the pod CIDR `10.244.0.0/16`, where Cilium's Envoy sends from. The default would trust all of `10.0.0.0/8`, LAN included.

### Route

The `HTTPRoute` `actual` on the Shared Gateway's `https` listener, no forward auth (Actual has its own login). ExternalDNS publishes `budget.<domain>` to Home DNS from it.

### Login

- **authentik, OIDC only** (`ACTUAL_LOGIN_METHOD=openid`, `ACTUAL_ALLOWED_LOGIN_METHODS=openid`, `ACTUAL_OPENID_ENFORCE=true`). The server writes the OpenID config into `account.sqlite` at every start from the `ACTUAL_OPENID_*` vars. No password login, so no break-glass login while authentik is down.
- The provider and application come from the blueprint `kubernetes/apps/auth/authentik/app/blueprints/actual.yaml`, and only `authentik Admins` may use it. Callback: `/openid/callback`.
- **Accounts**: the first person to log in becomes the owner (ADMIN). Others need a user created for them first in Actual's *User Directory* (`ACTUAL_USER_CREATION_MODE=manual`, the default).
- **The client secret** is in two SOPS Secrets that must hold the same value: `ACTUAL_OPENID_CLIENT_SECRET` in `actual-secrets` (`actual`) and `ACTUAL_OIDC_CLIENT_SECRET` in `authentik-actual-oidc` (`auth`). authentik's worker reads it at start, so restart it after changing it.

## First start

1. Commit, push, `just bootstrap::reconcile`. Restart authentik's worker so it picks up `authentik-actual-oidc`: `kubectl -n auth rollout restart deployment authentik-worker`. Once the blueprint has applied, restart Actual too if it started first: `kubectl -n actual rollout restart deployment actual`.
2. Open `https://budget.<domain>` and log in with authentik. That first login becomes the owner.
3. Create a budget, or import one (*Import file* takes Actual exports, YNAB4 and nYNAB).

## Upgrades

Renovate bumps the image tag. Actual releases monthly (`YY.MM.patch`). Read the release notes before a bump: the server migrates `account.sqlite` at start, and an older image can't be rolled back onto it without restoring the PVC from VolSync.

## Monitoring

- **No metrics**: Actual exposes none. The stack's generic rules cover crash loops and a pod that isn't ready, `VolSyncVolumeOutOfSync` the backup.
- **Logs**: in Loki under `{namespace="actual", app="actual"}`.
