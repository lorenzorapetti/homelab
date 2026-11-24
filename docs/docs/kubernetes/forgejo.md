---
sidebar_position: 5.9
sidebar_label: Forgejo
---

# Forgejo

[Forgejo](https://forgejo.org/) is the homelab's Git server, at `https://git.<domain>` and `ssh://git@git.<domain>`. Repositories are added by pushing them, or with Forgejo's **New migration** (from GitHub, Gitea and others).

## As built

The [Forgejo Helm chart](https://code.forgejo.org/forgejo-helm/forgejo-helm) `17.3.3` from OCI, in namespace `git`, running Forgejo 17.0.2. The chart defaults to the LTS (15.x), so the HelmRelease sets `image.tag` to the latest stable; check the chart's init scripts against a new major's CLI before bumping it. Files: `kubernetes/apps/git/forgejo/`.

- **Two Flux Kustomizations**, like authentik: `forgejo-db` (a one-instance CNPG `Cluster`, Postgres 18.7, 5Gi on Longhorn, archived to `s3://<bucket>/forgejo/forgejo-db/` on R2, [Backups: Postgres](/kubernetes/backups-postgres)), then `forgejo`, which waits for it.
- **Data**: PVC `forgejo` (10Gi, Longhorn), mounted at `/data`: repositories, LFS, attachments, avatars, the issue indexer and the generated `app.ini`. It's ours (`app/pvc.yaml`), not the chart's, so its name is stable. VolSync backs it up every night ([Backups: volumes](/kubernetes/backups-volsync)).
- **No Redis/Valkey** ([ADR 0002](https://github.com/lorenzorapetti/homelab/blob/main/docs/adr/0002-cloudnativepg-fresh-start.md)): cache in memory, the queue in LevelDB on the PVC, sessions in Postgres. With one replica, that's all it needs.
- **Settings** are chart values under `gitea.config` (one key per `app.ini` section). Secret ones come in as `FORGEJO__<SECTION>__<KEY>` env vars (`gitea.additionalConfigFromEnvs`): the database password from CNPG's `forgejo-db-app`, the rest from the SOPS Secret `forgejo-secrets`. The chart's init container writes them into `app.ini` at every start.
- **Mail** through Resend (`smtp.resend.com:587`, STARTTLS, user `resend`), like authentik. The API key and From address are `FORGEJO__MAILER__PASSWD` and `FORGEJO__MAILER__FROM` in `forgejo-secrets`.

### Routes

- **HTTPS**: the chart's `HTTPRoute` `forgejo` on the Shared Gateway's `https` listener, for the web UI only. ExternalDNS publishes `git.<domain>` to Home DNS from it. Git over HTTPS is off (`repository.DISABLE_HTTP_GIT`): clone and push go through SSH. This also keeps git away from Envoy's default 15s route timeout, which the Gateway's routes don't override.
- **SSH**: the chart's `TCPRoute` `forgejo-ssh` on the Gateway's `ssh` listener (TCP, port 22), which only accepts TCPRoutes from namespace `git`. SSH uses the same name and address as HTTPS, so it needs no DNS record of its own. In the pod, the rootless image's built-in SSH server listens on 2222 and Service `forgejo-ssh` maps 22 to it. A TCP listener has no hostnames, so port 22 on the Gateway belongs to Forgejo alone. This settles [open question 1](/kubernetes/adding-apps#open-questions) if it works; the fallback is a `LoadBalancer` Service on `10.0.12.2`.

### Login

- **authentik, OIDC.** The chart's init container creates (or updates) an OpenID Connect authentication source named `authentik`, with `forgejo admin auth add-oauth`. The provider and application come from the blueprint `kubernetes/apps/auth/authentik/app/blueprints/forgejo.yaml`, and only `authentik Admins` may use it. Forgejo reads the `groups` claim and makes members of `authentik Admins` Forgejo admins.
- **Accounts** are created on first login through authentik (`ALLOW_ONLY_EXTERNAL_REGISTRATION`), with the authentik username (`nickname` claim). Registration with a password is off, and nothing is visible without logging in (`REQUIRE_SIGNIN_VIEW`).
- **The client secret** is in two SOPS Secrets that must hold the same value: `secret` in `forgejo-oidc` (`git`) and `FORGEJO_OIDC_CLIENT_SECRET` in `authentik-forgejo-oidc` (`auth`). authentik's worker reads it at start, so restart it after changing it.
- **No passwords for authentik users**: they can't set a local one (`EXTERNAL_USER_DISABLE_FEATURES = manage_password`), and the API refuses HTTP Basic with a password (`ENABLE_BASIC_AUTHENTICATION = false`). Use API tokens.
- **Repositories** are private by default, and `git push` over SSH to a repo that doesn't exist yet creates it (`ENABLE_PUSH_CREATE_USER`). `git gc` runs on every repo every 72h (`cron.git_gc_repos`).
- **Break-glass admin**: the local user `forgejo-admin`, password in Secret `forgejo-admin`. The chart creates it on first start and never resets the password (`initialOnlyNoReset`). Use it only when authentik is down.

## First start

1. Put the Resend API key and the From address into `forgejo-secrets` (they are `CHANGEME-…` placeholders): `sops kubernetes/apps/git/forgejo/app/secret.sops.yaml`.
2. Commit, push, `just bootstrap::reconcile`. `forgejo-db`, then `forgejo` should go Ready.
3. Log in at `https://git.<domain>` with **Sign in with authentik**. Your account is created and is an admin.
4. Add your SSH key under **Settings → SSH / GPG Keys** and test with `ssh -T git@git.<domain>`.

## Monitoring

- **Metrics**: Forgejo's `/metrics` (counts of repositories, users, issues, …) on the `http` port, behind a bearer token (`FORGEJO__METRICS__TOKEN`) because the HTTPRoute would otherwise publish it. `app/servicemonitor.yaml` sends the token; the chart's own ServiceMonitor can't. Job `forgejo-http`, every 60s.
- **No dashboard or Forgejo alerts**: the metrics are counts, not health. The stack's generic rules cover crash loops and a pod that isn't ready, `CNPG*` cover the database and `VolSyncVolumeOutOfSync` the data backup.
- **Logs**: in Loki under `{namespace="git", app="forgejo"}`.
