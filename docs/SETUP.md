# Setup Guide

End-to-end instructions to wire this platform to a GitHub repository and an
Azure subscription, ready for the first `Provision Infrastructure` run. The
guide assumes you have **Owner** rights on the target Azure subscription and
**admin** rights on the GitHub repository.

## What you'll end up with

- A GitHub repository hosting this platform code.
- Three GitHub Environments (`dev`, `staging`, `prod`), with optional
  approval gates on `prod`.
- An Azure App Registration + Service Principal authenticated to GitHub via
  OIDC — **no client secrets stored anywhere**.
- Four federated credentials covering the bootstrap workflow and the three
  per-environment plan jobs.
- The Service Principal granted the minimum RBAC roles needed to bootstrap
  state storage and plan infrastructure changes.

Estimated time: **15–20 minutes** the first time.

---

## Prerequisites

Tooling on your workstation:

| Tool | Minimum version | Notes |
|------|-----------------|-------|
| `git` | 2.30 | Push the repo to GitHub |
| `gh` (optional) | 2.40 | Convenient for env/secret commands |
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

GitHub access:

- A GitHub account or organization where you'll host the repository.
- The ability to create Environments (free for public repos and for private
  repos on paid plans).

---

## Step 1 — Push the repository to GitHub

1. Create an empty repository on GitHub (e.g. `your-org/workshop-platform-eng`),
   without initial README, license, or `.gitignore`.
2. From the local checkout of this project:

   ```bash
   git init
   git add .
   git commit -m "feat: initial platform engineering scaffold"
   git branch -M main
   git remote add origin https://github.com/<your-org>/<repo-name>.git
   git push -u origin main
   ```

> **Note.** All federated credentials below tie OIDC tokens to this exact
> repository slug and to the `main` branch. If you push to a different branch
> or rename the repo later, you must update the federated credentials too.

---

## Step 2 — Create the GitHub Environments

GitHub Environments are referenced by the `plan` job's `environment:` key,
which is what makes per-environment OIDC subjects work. Create them even if
you don't add protection rules yet.

In the repository: **Settings → Environments → New environment**, and create:

| Environment | Suggested protection rules |
|-------------|----------------------------|
| `dev` | _(none)_ |
| `staging` | _(none for now)_ |
| `prod` | _Required reviewers_: at least one trusted reviewer |

You can also create them from the CLI if `gh` is set up:

```bash
gh api -X PUT repos/<your-org>/<repo-name>/environments/dev
gh api -X PUT repos/<your-org>/<repo-name>/environments/staging
gh api -X PUT repos/<your-org>/<repo-name>/environments/prod
```

---

## Step 3 — Create the Azure App Registration

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

# Capture the subscription ID — you'll pass this as `subscription_id`
SUBSCRIPTION_ID=$(az account show --query id -o tsv)

cat <<EOF

Save these three values — you'll feed them to the workflow as inputs:

  azure_client_id : $APP_ID
  azure_tenant_id : $TENANT_ID
  subscription_id : $SUBSCRIPTION_ID

  (SP object ID, only used in the next steps: $SP_OBJECT_ID)
EOF
```

> **Tip.** The App Registration's `appId` and the Service Principal's
> `objectId` are different identifiers. RBAC assignments and federated
> credentials work with the SP. Keep both handy.

---

## Step 4 — Configure federated credentials (OIDC)

The workflows authenticate to Azure with short-lived OIDC tokens issued by
GitHub Actions. Azure validates each token against a **federated credential**
on the App Registration. The token's `subject` claim must match exactly.

You need **four** credentials because two different subject formats apply:

| Credential | Used by | Subject |
|------------|---------|---------|
| Branch-scoped | `bootstrap-tfstate.yml`; the `bootstrap-tfstate` job in `provision-infrastructure.yml` | `repo:<org>/<repo>:ref:refs/heads/main` |
| Environment `dev` | `plan` job for `dev` | `repo:<org>/<repo>:environment:dev` |
| Environment `staging` | `plan` job for `staging` | `repo:<org>/<repo>:environment:staging` |
| Environment `prod` | `plan` job for `prod` | `repo:<org>/<repo>:environment:prod` |

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

## Step 5 — Assign Azure RBAC roles

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
`repo:<owner>/<app>:environment:{dev,staging,prod}`). Without these, deploy
workflows in the new repo fail at `azure/login` with `AADSTS70021`.

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

Because staging and prod cannot be reached over HTTP from a GitHub-hosted
runner, the application repo's `deploy.yml` should validate differently per
env:

- **dev** — `azure/login` (OIDC), update the container image on the App
  Service, then `curl -fsS https://<webapp>.azurewebsites.net/health`.
- **staging / prod** — `azure/login` (OIDC), update the image, then use
  control-plane assertions only:
  ```bash
  az webapp show -g $RG -n $APP --query state -o tsv          # → Running
  az webapp config container show -g $RG -n $APP \
    --query linuxFxVersion -o tsv                             # contains the deployed image tag
  ```
  This proves the platform accepted the new image. App Service's built-in
  health check (configured in this module to hit `/health`) handles the
  "is it actually serving traffic?" question and marks unhealthy instances
  unavailable automatically — the platform's `verify` job assertions cover
  the rest.

Operators who need real HTTP smoke tests against PE-only environments
should run the deploy workflow on a self-hosted runner inside
`webapp_integration_subnet` (or a peered VNet). Out of scope for the
workshop baseline.

---

## Step 6 — Handle GitHub Advanced Security (optional)

The `checkov` job uploads its findings as SARIF to **Security → Code scanning**.
Code scanning requires GitHub Advanced Security, which is:

- Free for **public** repositories.
- A paid add-on for **private** repositories on personal accounts.

If you can't enable it, the upload step will fail. Either:

1. **Make the repository public** (recommended for this workshop), or
2. Disable the SARIF upload by adding `if: false` to the
   `Upload SARIF to GitHub Security tab` step in
   `.github/workflows/provision-infrastructure.yml`. The Checkov scan itself
   still runs and still fails the build on findings.

---

## Step 7 — Provide a `GH_PAT` secret for cross-repo operations

After the infrastructure is provisioned and verified, the workflow continues
into **application-repo bootstrap**: it creates a new repo from a template,
opens a tracking issue, configures GitHub Environments + variables, dispatches
the app's CI workflow and posts a summary back to the issue.

All of those operations write to **a different repository** than the one the
workflow runs in. The default `GITHUB_TOKEN` is scoped to this repo only and
cannot create repositories or write to other repos' environments/variables.

Provide a Personal Access Token (or a GitHub App installation token) as a
**repository secret** named `GH_PAT`, with these scopes:

| Scope | Used for |
|-------|----------|
| `repo` | Read/write the application repository (creation, issues, comments) |
| `workflow` | Dispatch the CI workflow in the application repo |
| `admin:repo_hook` _(optional)_ | Future drift-detection wiring |

Create one at <https://github.com/settings/tokens?type=beta> (fine-grained,
recommended) with the target organization and `Administration: Read and write`,
`Contents: Read and write`, `Issues: Read and write`, `Actions: Read and write`,
`Variables: Read and write`, `Environments: Read and write` repository
permissions. Save it as the `GH_PAT` secret on this platform repo.

> **Why a PAT and not the workflow token?** GitHub deliberately scopes
> `GITHUB_TOKEN` to the repository running the workflow. Cross-repo writes
> require a token whose installation/owner has access to the target.

---

## Step 8 — Trigger the first run

In the GitHub UI: **Actions → Provision Infrastructure → Run workflow**, and
provide:

| Input | Value for the first test |
|-------|--------------------------|
| `environment` | `dev` |
| `app_name` | `test-webapp` (3–22 chars, lowercase, digits, hyphens) |
| `subscription_id` | the GUID captured in step 3 |
| `azure_client_id` | the `appId` captured in step 3 |
| `azure_tenant_id` | the tenant GUID captured in step 3 |
| `container_image` | `mcr.microsoft.com/appsvc/staticsite:latest` |
| `container_registry_url` | _(leave empty — public image)_ |
| `template_repo` | the `<owner>/<name>` of the application template repo |
| `ci_workflow_file` | _(leave empty — defaults to `ci.yml`)_ |

### What you should observe

```
resolve-inputs           ✓ validated inputs, derived sttftestwebapp<sub8>
checkov · {dev|staging|prod}  ✓ no findings
fmt                      ✓ formatting clean
bootstrap-tfstate        ✓ rg-tfstate-test-webapp + storage account + container
plan · {env}             ✓ terraform plan generated, artifact uploaded
apply · {env}            ✓ terraform apply succeeded
verify · {env}           ✓ control-plane assertions passed
create-app-repo                      ✓ <owner>/<app_name> created from template (or skipped)
create-run-issue                     ✓ per-run tracking issue opened
configure-env · {env}                ✓ GitHub Environment + variables set
federated-credential · {env}         ✓ AAD subject registered on the SP
observe-ci                           ✓ template auto-triggered CI watched, build+test+dev-deploy succeeded
finalize                             ✓ summary posted as issue comment
```

The exact storage account name shows up in the `bootstrap-tfstate` job logs as
`TFSTATE_STORAGE_ACCOUNT=...`. The plan output (and the binary `tfplan` file)
is attached as a workflow artifact named
`tfplan-test-webapp-dev`, retained for 7 days.

No real infrastructure has been created at this point — only the state
storage account. The Terraform plan describes what _would_ be created if the
apply step were enabled.

---

## Troubleshooting

### `AADSTS70021: No matching federated identity record found`

The OIDC token's subject doesn't match any federated credential on the App
Registration. Re-check:

- The repo slug is exactly `<org>/<repo>` — case-sensitive.
- For environment subjects, the GitHub Environment exists with the exact
  name (`dev`, `staging`, `prod`) and the `plan` job runs against it.
- If you triggered the workflow from a branch other than `main`, the
  branch-scoped credential won't match. Either trigger from `main` or add
  another federated credential for that branch.

### `Insufficient privileges to complete the operation` in `configure-federated-credentials`

The job calls `az ad app federated-credential create`, which hits Microsoft
Graph (`POST /applications/{id}/federatedIdentityCredentials`). Two things
are required and people commonly stop after the first:

1. The SP is an **owner** of its own App Registration
   (`az ad app owner add …`).
2. The SP has the `Application.ReadWrite.OwnedBy` Graph application
   permission **with admin consent**.

Without (2), even a fully-owning SP gets `Insufficient privileges`. Run the
two-step procedure in *step 5 — Allow the SP to manage its own federated
credentials*. Step (2) requires a directory-role admin (Global,
Privileged Role, Cloud Application, or Application Administrator) — in a
corporate tenant this is usually an internal request.

### `AuthorizationFailed` during `bootstrap-tfstate`

The Service Principal lacks one of the three RBAC roles, or propagation hasn't
finished yet. Re-run after a minute. If it persists, re-run the
`az role assignment list` command from step 5 and confirm all three roles are
listed at subscription scope.

### `Failed to query container 'tfstate' on '<account>'` during `bootstrap-tfstate`

The script (`scripts/bootstrap-tfstate.sh`) traps this on the
`az storage container exists` call. Two possible causes:

1. **RBAC**: the SP has `Contributor` (control plane) but not
   `Storage Blob Data Contributor` (data plane). Re-check step 5.
2. **Network rules**: the storage account has `defaultAction = Deny` (e.g.
   created by an earlier version of the script, or modified manually). The
   GitHub-hosted runner has no fixed egress IP and is blocked. Fix:

   ```bash
   az storage account update \
     --name <account> --resource-group <rg> --default-action Allow
   ```

   The current bootstrap script keeps `defaultAction = Allow` by design — see
   the security-model note in step 5.

### `terraform init` fails with `Error refreshing state`

Most often a missing `Storage Blob Data Contributor` assignment. Same fix as
above. If RBAC is correct, double-check that the workflow is using
`use_oidc=true` in the `-backend-config` flags (it is, by default).

### CI in the new app repo fails with `denied: permission_denied: write_package`

The container push to GHCR (`docker push ghcr.io/<owner>/<repo>:<tag>`) is
rejected even though the platform workflow set the new repo's default
workflow permissions to `write`. Common causes, in rough order of frequency:

1. **The CI workflow declares its own `permissions:` block** that omits
   `packages: write`. The block replaces the default — it doesn't merge with
   it. The workflow must include all the scopes it needs, e.g.
   `contents: read`, `packages: write`, `id-token: write`.

2. **The login step uses the wrong token or username.** For `docker
   login ghcr.io`, expect `username: ${{ github.actor }}` and
   `password: ${{ secrets.GITHUB_TOKEN }}` — typos or a stale PAT will fail
   with the same `denied` error.

3. **Org-level setting overrides the repo setting.** Org admins can lock
   workflow permissions at *Settings → Actions → General* with override
   disabled. The repo-level PUT is silently ignored. Ask the org admin to
   allow per-repo overrides or set the org default to `write`.

4. **Image namespace mismatch.** GHCR only accepts pushes to
   `ghcr.io/<owner>/<name>` where `<owner>` matches the repo owner. A tag
   computed against a different org/user is rejected.

5. **A pre-existing GHCR package linked to a different repo (or unlinked).**
   If a package with the same name already exists in the owner's namespace
   from a deleted repo or earlier experiment, GHCR refuses pushes from this
   repo even with correct permissions. Visit
   `https://github.com/orgs/<owner>/packages` (or
   `/users/<owner>/packages`), open the package's settings and either
   **delete** it or use **Manage Actions access** to link it to the new
   repository.

Useful diagnostic command:

```bash
gh run view <run-id> -R <owner>/<app> --log-failed
```

### Checkov reports new findings after a Terraform change

Either fix the finding or, if you've judged it a false positive or
not-applicable, add a justified entry to `.checkov.yaml` documenting why the
check is skipped. See [`CONTRIBUTING.md`](../CONTRIBUTING.md#terraform) for
the rules around skips.

---

## What's next

Once the first plan succeeds end-to-end, you're ready for the next milestones
on the [roadmap](../README.md#roadmap):

- Wire up the `apply` step with environment protection rules.
- Add repository templating so a brand-new application gets both its
  infrastructure and its source repo provisioned in one shot.
