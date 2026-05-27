# platform-gitops

Single-repo (monorepo) GitOps layout for the AKS platform managed by
`terraform-azure-avm-ptn-aks-argocd`. Holds:

- The Argo CD bootstrap Applications (`argocd/`).
- Raw / Helm component manifests they point at (`components/`).
- Per-team configuration files that drive team onboarding (`config/teams/`).
- Per-team workload manifests in monorepo form (`teams/<name>/services/`).

```
.
├── argocd/                         # Sync-waved bootstrap Applications
│   ├── eso.yaml                    #  wave 0  - External Secrets Operator
│   ├── eso-cluster-secret-store.yaml
│   ├── grafana-monitoring-secret.yaml
│   ├── argocd-oidc-secret.yaml     #  wave 1  - Entra OIDC client secret ESO
│   ├── tls-wildcard.yaml
│   ├── grafana-k8s-monitoring.yaml #  wave 2
│   ├── external-dns.yaml
│   ├── argocd-self-manage.yaml     #  wave 3  - Argo manages its own Helm + OIDC
│   ├── platform-gateway.yaml
│   └── teams.yaml                  #  wave 4  - team fan-out ApplicationSet
├── components/
│   ├── teams/                      # team-resources Helm chart (one render per team)
│   ├── argocd-oidc-secret/         # ExternalSecret for the OIDC client secret
│   └── ...
├── config/
│   └── teams/<name>.yaml           # one file per team — the onboarding entrypoint
├── teams/
│   ├── team-a/services/<svc>/...   # team-owned service manifests
│   └── team-b/services/<svc>/...
├── CODEOWNERS
└── README.md                       # this file
```

## Contents

1. [Bootstrap order](#bootstrap-order)
2. [Prerequisite: Configure Entra ID app registration](#prerequisite-configure-entra-id-app-registration)
3. [Entra group conventions](#entra-group-conventions)
4. [Onboarding a new team](#onboarding-a-new-team)
5. [Team config schema](#team-config-schema)
6. [RBAC reference](#rbac-reference)
7. [Operational notes](#operational-notes)

---

## Bootstrap order

Argo CD runs each `argocd/*.yaml` Application in the order dictated by its
`argocd.argoproj.io/sync-wave` annotation:

| Wave | Application(s) | Purpose |
|------|----------------|---------|
| 0 | `eso`, `eso-cluster-secret-store` | External Secrets Operator + Key Vault store |
| 1 | `argocd-oidc-secret`, `grafana-monitoring-secret`, `tls-wildcard` | Secrets that downstream waves depend on |
| 2 | `grafana-k8s-monitoring`, `external-dns` | Platform services |
| 3 | `argocd-self-manage` | Argo CD adopts its own Helm release (incl. Entra OIDC) |
| 4 | `teams` | Team fan-out ApplicationSet |

Terraform installs Argo CD and applies the wave-0..4 Applications once.
Everything after that — including Argo CD's own configuration — is driven from
this repo.

---

## Prerequisite: Configure Entra ID app registration

One-time, per environment, before the platform can authenticate users.
You produce five values:

| Output | Where it's used |
|---|---|
| Entra tenant ID | `argocd/argocd-self-manage.yaml` → `<ENTRA_TENANT_ID>` |
| App (client) ID | `argocd/argocd-self-manage.yaml` → `<ARGOCD_ENTRA_APP_CLIENT_ID>` |
| Client secret | Key Vault → `argocd-oidc-client-secret` (synced into `argocd-secret`) |
| Platform admin group object ID | `argocd/argocd-self-manage.yaml` → `<PLATFORM_ADMIN_GROUP_OBJECT_ID>` |
| Team group object IDs | `config/teams/<name>.yaml` → `entraGroups.*` |

### Step 1 — Create the app registration

Portal: **Entra ID → App registrations → New registration**.

| Field | Value |
|---|---|
| Name | `argocd-<env>` (e.g. `argocd-prod`) |
| Supported account types | Single tenant |
| Redirect URI (Web) | `https://argocd.<platform-domain>/auth/callback` |

CLI equivalent:

```sh
az ad app create \
  --display-name argocd-prod \
  --sign-in-audience AzureADMyOrg \
  --web-redirect-uris https://argocd.<platform-domain>/auth/callback

# Capture outputs:
APP_ID=$(az ad app list --display-name argocd-prod --query "[0].appId" -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
```

### Step 2 — Add the CLI redirect URI (recommended)

Add a second Web redirect URI so developers can run `argocd login --sso` from
their workstations:

```
http://localhost:8085/auth/callback
```

### Step 3 — Create a client secret

Portal: **Certificates & secrets → New client secret**.
- Lifetime: 12 or 24 months. Record the rotation date in your runbook.

CLI:

```sh
SECRET=$(az ad app credential reset \
  --id "$APP_ID" --append --years 2 \
  --query password -o tsv)

# Store immediately in Key Vault. Name must match argocd-oidc-secret.yaml.
az keyvault secret set \
  --vault-name <KEYVAULT_NAME> \
  --name argocd-oidc-client-secret \
  --value "$SECRET"
```

The ExternalSecret in `components/argocd-oidc-secret/external-secret.yaml`
pulls this into `argocd-secret` under the key `oidc.entra.clientSecret`,
referenced from `oidc.config` as `$oidc.entra.clientSecret`.

### Step 4 — Configure the ID token

Portal: **Token configuration**.

1. **Add optional claim → ID token**: check `email`, `preferred_username`.
2. **Add groups claim**:
   - Check **Security groups**.
   - Also check **Groups assigned to the application** if you plan to filter
     (recommended — see step 6).
   - Under "Customize token properties by type" → **ID** → **Group ID**.
     This emits each group as its **object ID (GUID)**, not as
     `sAMAccountName` or DNS name. Object IDs are what `AppProject.spec.roles[].groups`
     matches against, and they're stable across rename.

### Step 5 — API permissions

Portal: **API permissions → Add a permission → Microsoft Graph → Delegated**.
Add: `openid`, `profile`, `email`, `User.Read`. Then **Grant admin consent**.

CLI:

```sh
az ad app permission admin-consent --id "$APP_ID"
```

### Step 6 — (Recommended) Restrict the groups claim to assigned groups

Without this, every group the user belongs to is emitted in the ID token.
Users in large tenants hit Entra's 200-group overage limit, after which the
token only contains a `_claim_names` link to Graph — and Argo CD will *not*
follow it. Result: those users appear to have no groups and fall back to
`role:readonly`.

Two-step fix:

1. **Enterprise application → Properties** (the SP that was created
   automatically alongside the app registration):
   - Set **Assignment required?** = **Yes**.
2. **Enterprise application → Users and groups**:
   - Assign the platform-admins group and every team's owner / developer /
     viewer groups.

Then in **Token configuration → groups claim**, select **Groups assigned to
the application**.

### Step 7 — Wire outputs into the manifests

Replace placeholders:

```sh
# argocd/argocd-self-manage.yaml
#   <PLATFORM_DOMAIN>                  -> your ingress domain
#   <ENTRA_TENANT_ID>                  -> $TENANT_ID
#   <ARGOCD_ENTRA_APP_CLIENT_ID>       -> $APP_ID
#   <PLATFORM_ADMIN_GROUP_OBJECT_ID>   -> az ad group show --group <platform-admins> --query id -o tsv
#   <ARGOCD_REPO_IDENTITY_CLIENT_ID>   -> from Terraform WS1 outputs

# components/argocd-oidc-secret/external-secret.yaml
#   no edits — references the fixed Key Vault key "argocd-oidc-client-secret"

# argocd/argocd-oidc-secret.yaml + every other argocd/*.yaml
#   <PLATFORM_GITOPS_REPO_URL>         -> the URL of this repo
```

### Verification

After bootstrap and once `argocd-self-manage` is `Synced`:

```sh
# SSO login (opens browser to Entra).
argocd login argocd.<platform-domain> --sso

# Confirm the groups claim made it through.
argocd account get-user-info
# Expect: Groups: <guid-1>, <guid-2>, ...

# As a member of <team>-developers:
argocd app sync <team>-<service>     # should succeed
argocd app sync <other-team>-*       # should be denied

# As a member of platform-admins:
argocd proj list                      # should list every project
```

If `argocd account get-user-info` shows no groups, you've hit the overage
limit — apply step 6.

---

## Entra group conventions

Recommended naming (per environment):

| Group name | Object ID lands in | Grants |
|---|---|---|
| `aks-<env>-platform-admins` | `argocd-self-manage.yaml` `policy.csv` | `role:admin` on the whole instance |
| `aks-<env>-<team>-owners` | `config/teams/<team>.yaml` `entraGroups.owners` | Project `owner` |
| `aks-<env>-<team>-developers` | `config/teams/<team>.yaml` `entraGroups.developers` | Project `developer` |
| `aks-<env>-<team>-viewers` | `config/teams/<team>.yaml` `entraGroups.viewers` | Project `viewer` |

Look up object IDs:

```sh
az ad group show --group aks-prod-team-a-developers --query id -o tsv
```

---

## Onboarding a new team

Four-step contract:

1. **Platform admin** creates `config/teams/<name>.yaml`. See
   [Team config schema](#team-config-schema). At minimum: `name`, `appPath`,
   `entraGroups`, `quota`. This file gates everything; it stays under platform
   review (see CODEOWNERS).
2. **Platform admin** adds a CODEOWNERS line for `/teams/<name>/` pointing at
   the team's GitHub/ADO group, so the team can self-merge changes to their
   own service manifests.
3. **Team** creates their service manifests under `teams/<name>/services/<service>/`.
   Each subdirectory under `appPath` becomes one Argo Application. Typical
   layout uses the shared Helm chart with per-service values:

   ```yaml
   # teams/team-a/services/orders/Chart.yaml
   apiVersion: v2
   name: orders
   version: 0.1.0
   dependencies:
     - name: app
       version: 1.4.2
       repository: https://dev.azure.com/org/project/_git/helm-charts
   ```

   ```yaml
   # teams/team-a/services/orders/values.yaml
   app:
     image:
       repository: org.azurecr.io/team-a/orders
       tag: v1.2.3
     replicas: 3
   ```

4. **Open a PR.** After merge:
   - The platform `teams` ApplicationSet sees the new config file and renders
     the team-resources chart, creating the namespace, AppProject (with the
     Entra group bindings), ResourceQuota, LimitRange, NetworkPolicy, workload
     identity ServiceAccount, and the team's services ApplicationSet.
   - That services ApplicationSet picks up each subdirectory under `appPath`
     and creates one Application per service.

### Removing a team

Delete `config/teams/<name>.yaml`. The platform ApplicationSet's automated
sync prunes the team's Application; the `resources-finalizer.argocd.argoproj.io`
finalizer cleans up the namespace, AppProject, quota, limit range, network
policy, and service ApplicationSet. The team's workload manifests in
`teams/<name>/` can be deleted in the same PR.

---

## Team config schema

See [`components/teams/values.yaml`](components/teams/values.yaml) for the
authoritative schema with comments. Quick reference:

```yaml
# config/teams/team-a.yaml
name: team-a                                   # required; namespace + AppProject name
repoUrl: ""                                    # empty = monorepo (recommended)
revision: main
appPath: teams/team-a/services                 # required

sharedChartRepoUrl: https://...                # optional, whitelisted in AppProject
identityClientId: <guid>                       # optional, for workload identity SA

entraGroups:                                   # all lists optional, all default to []
  owners:     ["<guid>"]
  developers: ["<guid>"]
  viewers:    ["<guid>"]

quota:                                         # required in production
  requests: { cpu: "8",  memory: "16Gi" }
  limits:   { cpu: "16", memory: "32Gi" }
  pods: "50"
  persistentvolumeclaims: "10"
  services: "20"
  servicesLoadBalancers: "0"
  secrets: "100"
  configmaps: "100"

limitRange:                                    # recommended
  defaultRequest: { cpu: "100m", memory: "128Mi" }
  default:        { cpu: "500m", memory: "512Mi" }
  max:            { cpu: "2",    memory: "4Gi" }

networkPolicy:                                 # default-deny ingress
  allowFromNamespaces: ["istio-system", "argocd"]
```

---

## RBAC reference

| Role | What members can do |
|---|---|
| `role:admin` (platform admins via `argocd-rbac-cm`) | Everything: edit AppProjects, manage repo credentials, sync any Application. |
| AppProject `owner` | Full control over the team's Applications and AppProject membership. Can sync, edit, delete, exec into pods, view logs. |
| AppProject `developer` | Get / sync / run actions on the team's Applications. View logs. Cannot edit AppProject or grant access. |
| AppProject `viewer` | Read-only view of the team's Applications and logs. |
| `role:readonly` (default, unauthenticated-but-logged-in users) | List Applications and AppProjects; cannot sync or edit. |

Because `AppProject.spec.namespaceResourceBlacklist` includes ResourceQuota,
LimitRange, and NetworkPolicy, teams **cannot** create or modify those
objects from their own service manifests — only the platform-rendered
team-resources chart can. To change a quota, edit `config/teams/<team>.yaml`.

---

## Operational notes

### Rotating the Entra client secret

```sh
NEW=$(az ad app credential reset --id "$APP_ID" --append --years 2 --query password -o tsv)
az keyvault secret set --vault-name <KV> --name argocd-oidc-client-secret --value "$NEW"

# ESO picks up the new value within refreshInterval (1h). Force immediately:
kubectl annotate externalsecret -n argocd argocd-oidc-client-secret \
  force-sync=$(date +%s) --overwrite

# Restart argocd-server so it re-reads argocd-secret:
kubectl rollout restart deploy/argocd-server -n argocd
```

### Per-environment isolation

One app registration per ArgoCD instance (dev / stage / prod). Do **not**
share an app registration across environments — redirect URIs and group
assignments differ.

### Break-glass

The local `admin` account is **disabled** in `argocd-self-manage.yaml`
(`configs.cm.admin.enabled: "false"`), so SSO is the only login path during
normal operation. If Entra is unreachable or misconfigured:

1. Edit `argocd/argocd-self-manage.yaml` and set `admin.enabled: "true"`.
2. Commit + push. `argocd-self-manage` syncs in seconds.
3. Reveal (or reset) the admin password:
   ```sh
   # Show the bcrypt-hashed password currently in argocd-secret:
   kubectl -n argocd get secret argocd-secret \
     -o jsonpath='{.data.admin\.password}' | base64 -d
   # Or reset to a new value:
   argocd admin initial-password -n argocd
   ```
4. Log in as `admin`, fix the SSO problem, then revert step 1.

If Argo CD itself is broken badly enough that `self-manage` can't sync, the
escape hatch is `kubectl -n argocd edit cm argocd-cm` directly — but any
manual edit will be reverted on the next successful self-manage sync, which
is exactly what you want once you're recovered.

> Do **not** leave `admin.enabled: "true"` in main. CI should reject PRs that
> flip it without a matching revert commit.

### Auditing

- **Entra sign-in logs** show who logged in.
- **`argocd-server` audit logs** show what they did (correlate by the `sub`
  claim).
- Sync events are surfaced in the ArgoCD UI and as Kubernetes events on the
  Application object.

---

## Out of scope

This repo intentionally does **not** manage:

- The per-team UAMI + federated credential. Teams produce a `clientId`
  by whatever mechanism the org standardizes on (Terraform module, ServiceNow
  request, etc.) and put it in their config file. Provisioning patterns are
  documented in the parent Terraform module, not here.
- The Entra app registration itself. One-time setup per environment, owned by
  the identity team. See the prerequisite section above.
- The shared Helm chart repo contents. Teams reference it; the platform
  whitelists it in the AppProject; nobody in this repo owns the charts in it.
