---
sidebar_position: 2
sidebar_label: Grafana login
---

# Grafana login

Grafana logs you in with authentik, through Grafana's own OIDC support (generic OAuth). This is option 3 of the [migration plan](/kubernetes/migration#authentik-forward-auth-with-cilium-gateway): unlike Prometheus and Alertmanager, Grafana's route has no `ExternalAuth` filter, because Grafana has its own login and users.

The login page shows **Sign in with authentik** above the local login form. The local form stays, for the break-glass `admin` user.

## The authentik provider and application

Everything on the authentik side comes from the blueprint `kubernetes/apps/auth/authentik/app/blueprints/grafana.yaml`, mounted into the worker like the [forward-auth one](/kubernetes/observability/intro#authentik-forward-auth). Under **Customization → Blueprints**, "Grafana OIDC" should show as *successful*. It creates:

| Object | Settings |
| --- | --- |
| OAuth2/OpenID provider `Grafana` | Confidential client, client ID `grafana`. Redirect URI `https://grafana.<domain>/login/generic_oauth`, and `https://grafana.<domain>/login` after logout. Scopes `openid`, `email`, `profile` (which carries `groups`). Tokens signed RS256 with "authentik Self-signed Certificate". Implicit-consent authorization flow. Invalidation flow `default-invalidation-flow` (see [Logging out](#logging-out)) |
| Application `Grafana`, slug `grafana` | Launch URL `https://grafana.<domain>`. The slug is part of the end-session URL Grafana signs out through |
| Policy binding on the application | Group `authentik Admins` only |

Grafana's side is chart values in `kube-prometheus-stack/app/helmrelease.yaml` (`grafana.grafana.ini.auth.generic_oauth`): authentik's authorize, token and userinfo endpoints on `https://auth.<domain>/application/o/`, PKCE, and the claims for login (`preferred_username`), name, email and groups.

Grafana's pod calls the token and userinfo endpoints by the public name `auth.<domain>`. Inside the cluster that resolves, through Home DNS, to the Gateway address, so the calls go through the Shared Gateway with its public certificate.

### The client secret

The client secret is one random value kept in two SOPS Secrets, one per namespace:

| Namespace | Secret | Key | Read by |
| --- | --- | --- | --- |
| `auth` | `authentik-secrets` (`authentik/app/secret.sops.yaml`) | `GRAFANA_OIDC_CLIENT_SECRET` | The blueprint, as `!Env GRAFANA_OIDC_CLIENT_SECRET`. The chart loads the whole Secret into the server's and worker's env |
| `observability` | `grafana-oidc` (`kube-prometheus-stack/app/grafana-oidc.sops.yaml`) | `client-secret` | Grafana, as `GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET` |

Neither pod restarts when its Secret changes. To rotate the secret:

```sh
SECRET=$(head -c 64 /dev/urandom | base64 -w0 | tr -d '/+=' | head -c 64)
sops set kubernetes/apps/auth/authentik/app/secret.sops.yaml \
  '["stringData"]["GRAFANA_OIDC_CLIENT_SECRET"]' "\"$SECRET\""
sops set kubernetes/apps/observability/kube-prometheus-stack/app/grafana-oidc.sops.yaml \
  '["stringData"]["client-secret"]' "\"$SECRET\""
# commit, push, let Flux reconcile, then:
kubectl rollout restart -n auth deploy/authentik-worker        # re-applies the blueprint with the new value
kubectl rollout restart -n observability deploy/kube-prometheus-stack-grafana
```

## Groups and roles

**Only `authentik Admins` can use Grafana, and they are Grafana server admins.** Everyone else is denied; there is no Viewer fallback. This matches Prometheus and Alertmanager, which also let in `authentik Admins` only.

It is enforced twice:

1. **In authentik**: the application's policy binding refuses anyone outside `authentik Admins` before they reach Grafana.
2. **In Grafana**: `role_attribute_path` is `contains(groups[*], 'authentik Admins') && 'GrafanaAdmin' || ''`, with `role_attribute_strict: true`. `GrafanaAdmin` makes the user a server admin and an Admin of the main org (`allow_assign_grafana_admin: true`). An empty role is refused.

Grafana syncs the role at every login, so a role changed in Grafana's UI is overwritten next time. To change who gets what, change the group in authentik.

To let someone in as a Viewer later: add a policy binding for their group to the application in the blueprint, and extend the expression, e.g. `contains(groups[*], 'authentik Admins') && 'GrafanaAdmin' || contains(groups[*], 'Grafana Viewers') && 'Viewer' || ''`.

## Logging out

Grafana's sign-out sends the browser to authentik's end-session endpoint, `https://auth.<domain>/application/o/grafana/end-session/` (`signout_redirect_url`). authentik then runs the provider's invalidation flow. The provider uses `default-invalidation-flow`, whose logout stage ends the authentik session too, rather than `default-provider-invalidation-flow`, which only ends the session with Grafana. So after signing out of Grafana, Prometheus and Alertmanager also ask you to log in again.

## Break-glass: the local admin

If authentik is down, or the OIDC config is broken, log in with the local `admin` user from the form under **Sign in with authentik**. Its password is in Secret `kube-prometheus-stack-grafana`, which the chart generated on first install:

```sh
kubectl get secret kube-prometheus-stack-grafana -n observability \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

- Grafana copies the admin user into its database on first start only. A password changed in Grafana's UI lives in Postgres, and the Secret no longer matches it. If you change it, update the Secret by hand too, or reset the password to the Secret's value with `kubectl exec -n observability deploy/kube-prometheus-stack-grafana -c grafana -- grafana cli admin reset-admin-password "<password>"`.
- The admin user is separate from your authentik user: they have different logins (`admin` and your authentik username), so Grafana never merges them.

## Checks

In a private window:

1. `https://grafana.<domain>` shows the login page with **Sign in with authentik**.
2. Signing in with an `authentik Admins` user lands on the home dashboard. **Administration → Users** shows the user as Grafana Admin, with the Admin role in Main Org, and "authentik" as its auth method.
3. Signing out lands on authentik's logout page. Opening `https://prometheus.<domain>` then asks you to log in again.
4. Signing in as a user outside `authentik Admins` is refused by authentik.
5. The local `admin` login, with the password from the Secret, still works.
