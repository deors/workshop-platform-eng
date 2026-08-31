---
title: Setup Guide for Azure
---

[← back to home](index.md)

# Setup Guide for Azure

Wires this platform to an **Azure subscription**: the identity it authenticates
with, the permissions it needs, and the storage account that holds Terraform
state. When you finish, the platform is ready for its first
`Azure - Provision & Reconcile Application Resources` run.

> **Do the [GitHub setup](setup-github.md) first.** This guide assumes the
> repository is already on GitHub and its `dev` / `staging` / `prod`
> Environments exist — the federated credentials below are scoped to that
> repository slug and those environment names.

It assumes you have **Owner** rights on the target Azure subscription.

## What you'll end up with

- An Azure App Registration + Service Principal authenticated to GitHub via
  OIDC — **no client secrets stored anywhere**.
- Four federated credentials covering the bootstrap workflow and the three
  per-environment plan jobs.
- The Service Principal granted the minimum RBAC roles needed to bootstrap
  state storage and plan infrastructure changes.

Estimated time: **10–15 minutes** the first time.

---

## Prerequisites

Tooling on your workstation, on top of what the GitHub guide lists:

| Tool | Minimum version | Notes |
|------|-----------------|-------|
| `az` | 2.60 | App Registration + RBAC + federated credentials |
| `jq` (optional) | 1.6 | Useful for inspecting `az` output |

Azure access:

- An existing Azure subscription where you have the **Owner** role (required
  to create role assignments at subscription scope).
- The subscription is registered with **Microsoft.Web**, **Microsoft.Storage**,
  **Microsoft.Network**, **Microsoft.OperationalInsights**, and
  **Microsoft.Insights** providers. They're registered by default in most
  subscriptions; if you hit `MissingSubscriptionRegistration` later, run
  `az provider register --namespace <namespace>`.

---

## Step 1 — Create the Azure App Registration

```bash
# Sign in to the right tenant if you have several
az login

# Make sure you're operating against the intended subscription
az account set --subscription "<your-subscription-id-or-name>"

# Create the App Registration
az ad app create --display-name "sp-platform-eng-github"

# Capture the appId — this is the value you'll pass as `azure_client_id`
APP_ID=$(az ad app list \
  --display-name "sp-platform-eng-github" \
  --query "[0].appId" -o tsv)

# Create the matching Service Principal in your tenant
az ad sp create --id "$APP_ID"

# Capture the SP object ID — needed for RBAC role assignments
SP_OBJECT_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv)

# Capture the tenant ID — you'll pass this as `azure_tenant_id`
TENANT_ID=$(az account show --query tenantId -o tsv)

# Capture the subscription ID — you'll pass this as `azure_subscription_id`
SUBSCRIPTION_ID=$(az account show --query id -o tsv)

cat <<EOF

Save these three values — you'll feed them to the workflow as inputs:

  azure_tenant_id : $TENANT_ID
  azure_subscription_id : $SUBSCRIPTION_ID
  azure_client_id : $APP_ID

  (SP object ID, only used in the next steps: $SP_OBJECT_ID)
EOF
```

> **Tip.** The App Registration's `appId` and the Service Principal's
> `objectId` are different identifiers. RBAC assignments and federated
> credentials work with the SP. Keep both handy.

---

## Step 2 — Configure federated credentials (OIDC)

The workflows authenticate to Azure with short-lived OIDC tokens issued by
GitHub Actions. Azure validates each token against a **federated credential**
on the App Registration. The token's `subject` claim must match exactly.

You need **four** credentials because two different subject formats apply:

| Credential | Used by | Subject |
|------------|---------|---------|
| Branch-scoped | every job in `provision-infrastructure.yml` **without** an `environment:` key — `resolve-inputs`, `fmt`, `checkov`, `bootstrap-tfstate`, `create-app-repo`, `create-run-issue`, `configure-environments`, `configure-federated-credentials`, `observe-ci`, `finalize`; and the standalone `bootstrap-tfstate.yml` | `repo:<org>/<repo>:ref:refs/heads/main` |
| Environment `dev` | every job pinned to `environment: dev` — `plan`, `apply`, the `verify-infrastructure.yml` reusable workflow | `repo:<org>/<repo>:environment:dev` |
| Environment `staging` | same set of jobs, pinned to `environment: staging` | `repo:<org>/<repo>:environment:staging` |
| Environment `prod` | same set of jobs, pinned to `environment: prod` | `repo:<org>/<repo>:environment:prod` |

> **Check your repo's subject format first.** GitHub embeds immutable IDs in
> the subject claim of any repository created (or renamed/transferred) after
> July 15, 2026: the prefix becomes `repo:<org>@<owner-id>/<repo>@<repo-id>`
> instead of `repo:<org>/<repo>`, and Entra matches subjects verbatim. Query
> the exact prefix your platform repo presents and use it in the four
> subjects below:
>
> ```bash
> gh api "repos/$REPO/actions/oidc/customization/sub" --jq .sub_claim_prefix
> ```
>
> The snippets below assume the legacy prefix, which is what a platform repo
> created before that date presents. The *app* repos the platform creates
> need no such care from you — the `configure-federated-credentials` job
> queries each new repo's actual prefix before registering its credentials.

Create all four:

```bash
REPO="<your-org>/<repo-name>"   # e.g. deors/workshop-platform-eng

# 1. Branch-scoped credential (bootstrap jobs)
az ad app federated-credential create --id "$APP_ID" --parameters '{
  "name":     "github-main-branch",
  "issuer":   "https://token.actions.githubusercontent.com",
  "subject":  "repo:'"$REPO"':ref:refs/heads/main",
  "audiences": ["api://AzureADTokenExchange"]
}'

# 2-4. One credential per GitHub Environment
for ENV in dev staging prod; do
  az ad app federated-credential create --id "$APP_ID" --parameters '{
    "name":     "github-env-'"$ENV"'",
    "issuer":   "https://token.actions.githubusercontent.com",
    "subject":  "repo:'"$REPO"':environment:'"$ENV"'",
    "audiences": ["api://AzureADTokenExchange"]
  }'
done

# Verify
az ad app federated-credential list --id "$APP_ID" \
  --query "[].{name:name, subject:subject}" -o table
```

You should see exactly four rows.

---

## Step 3 — Assign Azure RBAC roles

The Service Principal needs three roles at **subscription scope**. The third
one — `Storage Blob Data Contributor` — is the easy-to-miss one: the bootstrap
script creates the state storage account with `allow-shared-key-access=false`,
so the only way the script can then create the container is via RBAC. The role
must be in place **before the first run**.

```bash
SCOPE="/subscriptions/$SUBSCRIPTION_ID"

# Manage control-plane resources (RGs, App Service, networking, …)
az role assignment create \
  --assignee-object-id      "$SP_OBJECT_ID" \
  --assignee-principal-type ServicePrincipal \
  --role  "Contributor" \
  --scope "$SCOPE"

# Read/write state blobs (Contributor does NOT cover the data plane)
az role assignment create \
  --assignee-object-id      "$SP_OBJECT_ID" \
  --assignee-principal-type ServicePrincipal \
  --role  "Storage Blob Data Contributor" \
  --scope "$SCOPE"

# Create role assignments — needed for the webapp module's ACR pull and
# Key Vault access policy resources
az role assignment create \
  --assignee-object-id      "$SP_OBJECT_ID" \
  --assignee-principal-type ServicePrincipal \
  --role  "User Access Administrator" \
  --scope "$SCOPE"

# Verify
az role assignment list --assignee "$SP_OBJECT_ID" --scope "$SCOPE" \
  --query "[].roleDefinitionName" -o table
```

Expected output:

```
Result
-------------------------------
Contributor
Storage Blob Data Contributor
User Access Administrator
```

> **Why all three at subscription scope?** During bootstrap the
> resource group and storage account don't exist yet, so any role on a
> narrower scope wouldn't apply. Once we evolve the platform to provision
> infrastructure for many apps in many subscriptions, this RBAC model will
> be revisited (likely a per-subscription identity rather than a single
> shared SP).

### Allow the SP to manage its own federated credentials

After the platform provisions infrastructure for a new app, it must register
**three additional federated credentials** on this same App Registration —
one per environment, scoped to the new app repo (subjects
`repo:<owner>/<app>:environment:{dev,staging,prod}`, or the immutable-ID
variant `repo:<owner>@<id>/<app>@<id>:environment:{…}` that GitHub mints for
repos created after July 15, 2026 — the workflow queries the new repo for
whichever prefix it actually presents). Without these, deploy workflows in
the new repo fail at `azure/login` with `AADSTS700213`.

The platform workflow does this automatically (see job
`configure-federated-credentials`), but the SP needs **two** things to be
allowed to write to its own App Registration:

1. **Self-ownership** of the App Registration object (directory-level), and
2. The `Application.ReadWrite.OwnedBy` **application permission** on
   Microsoft Graph, with admin consent.

Ownership alone is sufficient for *user-delegated* flows but **not** for
*application-only* flows like the OIDC token a workflow runs under, even
in your own tenant — the corporate Entra default policy denies the call
with `Insufficient privileges to complete the operation`.

#### 1. Add the SP as owner of its own App Registration

```bash
APP_OBJECT_ID=$(az ad app show --id "$APP_ID" --query id -o tsv)

az ad app owner add \
  --id              "$APP_OBJECT_ID" \
  --owner-object-id "$SP_OBJECT_ID"

# Verify
az ad app owner list --id "$APP_OBJECT_ID" --query "[].id" -o tsv
```

#### 2. Grant `Application.ReadWrite.OwnedBy` on Microsoft Graph

This step **requires admin consent** in the tenant: a Global Administrator,
Privileged Role Administrator, Cloud Application Administrator, or
Application Administrator must run it (or grant consent in the portal). In a
corporate tenant this typically means filing an internal request.

```bash
# Microsoft Graph's well-known appId
GRAPH_APP_ID="00000003-0000-0000-c000-000000000000"
GRAPH_SP_ID=$(az ad sp show --id "$GRAPH_APP_ID" --query id -o tsv)

# AppRoleId for Application.ReadWrite.OwnedBy on Graph
ROLE_ID=$(az ad sp show --id "$GRAPH_APP_ID" \
  --query "appRoles[?value=='Application.ReadWrite.OwnedBy'].id | [0]" -o tsv)

# Grant it (admin consent required to execute this call)
az rest --method POST \
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${SP_OBJECT_ID}/appRoleAssignments" \
  --headers "Content-Type=application/json" \
  --body "{
    \"principalId\": \"${SP_OBJECT_ID}\",
    \"resourceId\":  \"${GRAPH_SP_ID}\",
    \"appRoleId\":   \"${ROLE_ID}\"
  }"

# Verify — should list one row with role 'Application.ReadWrite.OwnedBy'
az rest --method GET \
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${SP_OBJECT_ID}/appRoleAssignments" \
  --query "value[].{resource:resourceDisplayName, roleId:appRoleId}" -o table
```

#### Portal alternative

Entra ID → App registrations → your app → **API permissions** → **Add a
permission** → Microsoft Graph → **Application permissions** →
`Application.ReadWrite.OwnedBy` → **Add**. Then click **Grant admin consent
for &lt;tenant&gt;**.

> **Why `OwnedBy` and not `All`?** `Application.ReadWrite.OwnedBy` only lets
> the SP write to App Registrations where it is an owner (set in step 1
> above). `Application.ReadWrite.All` would let it write to *any* App
> Registration in the tenant — a much wider blast radius.

### Bootstrap storage account — security model

The state storage account is created with:

- `--allow-shared-key-access false` — disables SAS/account keys; **AAD auth is
  the only way in**, gated by `Storage Blob Data Contributor`. This is the
  primary security boundary.
- `--allow-blob-public-access false` — no anonymous blob reads.
- `--https-only true` and `--min-tls-version TLS1_2`.
- Public network endpoint **enabled** (`defaultAction = Allow`). GitHub-hosted
  runners have no fixed egress IPs, so a firewall (`defaultAction = Deny`)
  would block the bootstrap and every `terraform init`. AAD-only auth
  + RBAC is what protects the account, not the network layer.

If your threat model requires network-level isolation, switch to a Private
Endpoint and run the workflows on a self-hosted runner inside the VNet. That
trade-off is intentionally out of scope for the workshop baseline.

> **Backend implication.** Because the SA forbids shared-key auth, the
> azurerm backend must also be told to use Azure AD against the blob endpoint
> (not just for credential acquisition). The workflow sets both
> `use_oidc=true` and `use_azuread_auth=true` (plus `ARM_USE_AZUREAD=true`).
> Without the second flag, `terraform init` hits `403 KeyBasedAuthenticationNotPermitted`
> even with a valid OIDC token.

### Web App network exposure — per-environment policy

Application Web Apps follow a deliberate per-env split:

| Env | Private Endpoint | Public endpoint | Rationale |
|-----|------------------|-----------------|-----------|
| `dev` | enabled | **enabled** | GitHub-hosted runners are not in the VNet and have no fixed egress IP. The dev environment intentionally accepts public traffic so the application repo's CI/CD can run an HTTP smoke test against `https://<webapp>.azurewebsites.net/health` after each deploy. |
| `staging` | enabled | **disabled** | PE-only. Mirrors the production posture so any data flowing through staging is treated with the same network sensitivity as prod. |
| `prod` | enabled | **disabled** | PE-only. The only path in is from the integration subnet via the private endpoint. |

The toggle is a module variable, `public_network_access_enabled` (default
`false`). Dev sets it to `true` explicitly; staging/prod inherit the secure
default. `CKV_AZURE_222` (Public network access disabled) is enforced for
prod and skipped for dev/staging in `.checkov.nonprod.yaml` so the dev
exception doesn't fail policy.

#### Deploy validation strategy

The application repository ships **two top-level workflows** that both
delegate to a reusable `deploy.yml`:

- **`ci.yml`** — runs on every push to `main`; builds, tests, and calls
  `deploy.yml` with `environment: dev`. The dev Web App has its public
  endpoint open, so the deploy step can finish with a real HTTP smoke test
  (`curl -fsS https://<webapp>.azurewebsites.net/health`).
- **`release.yml`** — promotes an **existing GHCR digest** to staging and
  then to prod, triggered by a Git release (`vX.Y.Z-RC` → staging,
  `vX.Y.Z` → prod). It does **not rebuild** the image:

  1. *Identify image* — `az webapp config show` against the source env
     (`dev` for RC, `staging` for GA) to read the currently-deployed
     `sha-<short>` tag.
  2. *Retag* — `docker pull <sha-tag>` then `docker tag` + `docker push`
     to add the release tag to the same digest in GHCR. The same image
     ends up with multiple tags: `sha-abc1234`, `1.4.0-RC`, `1.4.0`.
  3. *Deploy* — calls `deploy.yml` with the target environment
     (`staging` after `vX.Y.Z-RC`, `prod` after `vX.Y.Z`), pointing
     App Service at the new tag. The prod environment's reviewers
     approve before the prod step runs.

  Because staging and prod are PE-only, the deploy step uses
  **control-plane assertions only**:
  ```bash
  az webapp show        -g $RG -n $APP --query state          -o tsv  # should be 'Running'
  az webapp config show -g $RG -n $APP --query linuxFxVersion -o tsv  # contains the deployed image tag
  ```
  This proves the platform accepted the new image. App Service's built-in
  health check (configured in this module to hit `/health`) handles the
  "is it actually serving traffic?" question and marks unhealthy instances
  unavailable automatically — the platform's `verify` job assertions cover
  the rest.

  The retag-not-rebuild model means the exact bits that passed CI are the
  exact bits in prod — no chance of a release-time rebuild drift, and every
  released digest is traceable back to its `sha-<short>` and the commit.

Operators who need real HTTP smoke tests against PE-only environments
should run the deploy/release workflows on a self-hosted runner inside
`webapp_integration_subnet` (or a peered VNet). Out of scope for the
workshop baseline.

---

## Step 4 — Trigger the first run

In the GitHub UI: **Actions → Azure - Provision & Reconcile Application
Resources → Run workflow**, and provide:

| Input | Required | Value for the first test |
| ----- | -------- | ------------------------ |
| `app_name` | yes | `test-webapp` (3–22 chars, lowercase, digits, hyphens) |
| `environment` | yes | `dev` |
| `azure_tenant_id` | yes | the tenant GUID captured in step 1 |
| `azure_subscription_id` | yes | the GUID captured in step 1 |
| `azure_client_id` | yes | the `appId` captured in step 1 |
| `location` | yes | `westeurope` — Azure region for the tfstate storage account and every provisioned resource. No default, by design: an implicit region silently deploys to the wrong place |
| `infra_template_repo` | yes | the `<owner>/<name>` of the infrastructure template repo |
| `infra_template_ref` | no | _(leave empty — uses the template's default branch)_ git ref (tag, branch, or commit SHA) to pin the infra template |
| `app_template_repo` | no | the `<owner>/<name>` of the application template repo; **leave empty to skip the app-repo phase** (infra-only run) |
| `app_template_ref` | no | _(leave empty — uses the template's default branch)_ git ref (tag, branch, or commit SHA) to pin the app template |
| `container_image` | no | `mcr.microsoft.com/appsvc/staticsite:latest` |
| `container_registry_url` | no | _(leave empty — public image)_ |
| `ci_workflow_file` | no | _(leave empty — defaults to `ci.yml`; only used when `app_template_repo` is set)_ |

### What you should observe

Each row below names the job exactly as it appears in the run's UI. Jobs
marked _(app phase)_ only appear when `app_template_repo` is provided.

```
Resolve inputs                    ✓ validated inputs, derived sttf<app><sub>
Checkov · {env}                   ✓ no findings
Terraform fmt check               ✓ formatting clean
Bootstrap tfstate storage         ✓ rg-test-webapp-tfstate + storage account + container
Plan · {env}                      ✓ terraform plan generated, artifact uploaded
Apply · {env}                     ✓ terraform apply succeeded
Verify · {env}                    ✓ control-plane assertions passed
Create application repo           ✓ <owner>/<app_name> created from template   (app phase)
Create run issue                  ✓ per-run tracking issue opened               (app phase)
Configure env · {env}             ✓ GitHub Environment + variables set          (app phase)
Federated credential · {env}      ✓ AAD subject registered on the SP            (app phase)
Observe CI in app repo            ✓ CI watched, build+test+dev-deploy succeeded (app phase, first run only)
Comment on app issue              ✓ summary posted as issue comment             (app phase)
Comment on infra issue            ✓ plan + verify results posted to infra issue
Final summary                     ✓ consolidated summary with links to issues
```

The exact storage account name shows up in the `bootstrap-tfstate` job logs as
`TFSTATE_STORAGE_ACCOUNT=...`. The plan output (and the binary `tfplan` file)
is attached as a workflow artifact named `tfplan-test-webapp-dev`, retained
for 7 days. The plan is then consumed by the `apply` job, which provisions
the resources for real, after which `verify` runs control-plane assertions
against the live infrastructure.

When `app_template_repo` is provided, the run also creates the application
repository from your template, configures its GitHub Environments + variables
(`AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `AZURE_CLIENT_ID`,
`AZURE_RESOURCE_GROUP`, `AZURE_WEBAPP_NAME`, `CONTAINER_REGISTRY_URL` when a
registry was supplied, and `DEPLOY_TARGET_CLOUD=azure` — the
environment-scoped switch the app repo's deploy router reads to pick its
cloud, so different environments of one app can target different clouds),
registers the per-env federated credentials on the platform SP, observes the
auto-triggered CI in the new repo, and posts a summary comment on the per-run
tracking issue. When `app_template_repo` is omitted, all of those steps are
skipped and only the infra issue and final summary are written.

---

## Step 5 — Configure scheduled drift detection (optional)

The `detect-drift.yml` workflow compares the recorded Terraform state against
the live Azure resources (`terraform plan -refresh-only`) and opens an issue in
the affected application's **infrastructure repo** (`<app>-infra`) when it finds
drift or an error. It has three entry points: a weekly `schedule` (Mondays at
06:00 UTC), manual `workflow_dispatch`, and `workflow_call` (so other workflows
can reuse it).

To change the cadence, edit the `cron` expression in `detect-drift.yml`. It
cannot be moved to a repository variable — GitHub does not evaluate `${{ }}`
expressions in the `on:` block, so a templated cron never fires. Scheduled runs
are also best-effort: GitHub delays them under load and disables them after 60
days of repository inactivity.

For each environment the workflow classifies the result from the
(managed-state × resource-group) matrix:

| Terraform state | Resource group | Result |
|-----------------|----------------|--------|
| empty / missing | absent | ⏭️ **skipped** — never provisioned |
| empty / missing | present | 🔴 **drift** — unmanaged/orphaned resource group |
| has resources | absent | 🔴 **drift** — all managed resources missing |
| has resources | present | refresh-only plan → ✅ no drift, 🔴 drift, or ⚠️ error |

When drift is found the run stays **green** and reports via an issue; the run
only goes **red** when the check itself errors (init/plan failure, missing
directory, unreadable state), so a real problem with the sweep is visible and
any `workflow_call` caller can react. The issue body carries the per-environment
status, a follow-up comment carries the structured breakdown
(added / removed / replaced / modified / tag-only), and the raw `terraform`
plan output, binary plan and plan JSON are uploaded to the run as the
`drift-<app>` artifact.

Manual and called runs pass their parameters as inputs. The **scheduled run
cannot** — GitHub `schedule` events carry no inputs — so it reads them from
**repository variables**, all `DRIFT_`-prefixed to make clear they exist solely
to drive the automated sweep:

| Repository variable | Required | Description |
|---------------------|----------|-------------|
| `DRIFT_AZURE_APP_NAMES` | yes | Application name(s) to check, comma-separated (e.g. `myapp,otherapp`). The workflow fans out one matrix job per app. |
| `DRIFT_AZURE_ENVIRONMENTS` | no | Environment(s) to check: `all` (default) or a comma-separated subset of `dev`/`staging`/`prod`. |
| `DRIFT_AZURE_TENANT_ID` | yes | Azure Tenant ID used for the OIDC login. |
| `DRIFT_AZURE_SUBSCRIPTION_ID` | yes | Azure Subscription ID hosting the apps' resources and tfstate. |
| `DRIFT_AZURE_CLIENT_ID` | yes | Client ID of the platform App Registration. |
| `DRIFT_AZURE_LOCATION` | yes | Azure region of the resources under check (e.g. `westeurope`). Required by the infra template; a refresh-only plan will not run without it. |

Set them under **Settings → Secrets and variables → Actions → Variables**, or
via the CLI:

```bash
gh variable set DRIFT_AZURE_APP_NAMES       -R <org>/<platform-repo> --body "test-webapp"
gh variable set DRIFT_AZURE_ENVIRONMENTS    -R <org>/<platform-repo> --body "all"
gh variable set DRIFT_AZURE_TENANT_ID       -R <org>/<platform-repo> --body "<tenant-guid>"
gh variable set DRIFT_AZURE_SUBSCRIPTION_ID -R <org>/<platform-repo> --body "<subscription-guid>"
gh variable set DRIFT_AZURE_CLIENT_ID       -R <org>/<platform-repo> --body "<client-guid>"
gh variable set DRIFT_AZURE_LOCATION        -R <org>/<platform-repo> --body "westeurope"
```

The drift job authenticates with the **branch-scoped** federated credential
(`repo:<org>/<repo>:ref:refs/heads/main`) already configured in step 2 — it is
read-only and never binds a GitHub Environment, so no extra OIDC subject is
needed. Issue creation in the `<app>-infra` repo uses the same `GH_PAT` secret
configured in the
[GitHub setup guide](setup-github.md).

If `DRIFT_AZURE_APP_NAMES` or any required input is missing, the scheduled
run fails fast with a clear error instead of silently doing nothing.

---

## Troubleshooting

Azure identity/login failures (`AADSTS70021`, `Insufficient privileges`) and
Terraform state problems (`AuthorizationFailed`, `Failed to query container`,
`Error refreshing state`) are collected in [Troubleshooting](troubleshooting.md):

- [Cloud integration and login](troubleshooting.md#cloud-integration-and-login)
- [Terraform state](troubleshooting.md#terraform-state)

For the Azure resources themselves — App Service, networking, the template's
Checkov baselines — see the
[infrastructure template's troubleshooting](https://github.com/deors/template-terraform-azure-webapp#troubleshooting).
---

## What's next

With the first run green end-to-end, the typical follow-up workshop topics are:

- **Iterate on the application** — push to the new repo's `main`; the
  template's **CI workflow** builds, tests, and (on success) deploys to dev.
- **Promote to staging / prod** — the template ships a **release workflow**
  that promotes a built image to staging and then to prod, using the same
  per-env GitHub Environments + variables this platform configured (so
  `prod` honours whatever protection rules / reviewers you've added on its
  environment). Trigger it by creating a GitHub Release in the app repo —
  `vX.Y.Z-RC` deploys to staging, `vX.Y.Z` deploys to prod — or run it
  manually from *Actions → Release → Run workflow* for ad-hoc promotions.
  The release workflow performs control-plane validation only against
  staging/prod — HTTP smoke tests don't work from a GitHub-hosted runner
  against PE-only envs (see *Web App network exposure* in step 3).
- **Try the self-service web UI** — enable GitHub Pages on this repo
  (`Settings → Pages → Source: Deploy from a branch / main / /docs`), then
  fire subsequent runs from `https://<owner>.github.io/<repo>/`. The page
  works for *provision* (new env on an existing app) and *reconcile* runs
  too, not just first-time bootstrap.
- **Pick the next item from the roadmap** — destroy/decommission, scheduled
  drift detection, container console logs in the module, and cost reporting
  are the most-requested next steps.
