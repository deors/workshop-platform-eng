---
title:       Workshop · Platform Engineering
description: Self-service Azure provisioning, driven by GitHub Actions + Terraform.
---

<!--
Pages-rendered homepage. This file is the canonical documentation source —
the repo's top-level README.md is intentionally a short pointer to this page
and does not duplicate the content below.
-->

**📚 Documentation:**
[Self-service provisioning ➜](provision.html) ·
[Setup guide](SETUP.md) ·
[Contributing](CONTRIBUTING.md) ·
[Pages info](PAGES.md) ·
[Source on GitHub]({{ site.github.repository_url }})

---

# Workshop · Platform Engineering

A self-service platform that provisions Azure infrastructure for containerised
web applications, driven by GitHub Actions and Terraform. External systems
trigger the platform through `repository_dispatch` or `workflow_dispatch` events;
the platform takes care of standing up secure, observable, production-grade
environments without the requesting team having to write any infrastructure code.

> **Status:** functional end-to-end. Plan → apply → verify, application repo
> creation from template, GitHub Environments + variables, OIDC federated
> credentials, CI observation and per-run tracking issue are all wired. See
> [Roadmap](#roadmap) for what's next.

---

## What this platform does

Given an existing Azure subscription, the platform provisions an opinionated
**Azure App Service (Linux, container)** stack for an application across three
environments — `dev`, `staging`, `prod` — following Microsoft's well-architected
guidance for security, observability, and connectivity:

- VNet integration for outbound traffic, Private Endpoint for inbound
- Per-env network exposure: dev is publicly reachable for HTTP smoke tests;
  staging and prod are PE-only
- User-assigned Managed Identity (no credentials in app settings)
- Key Vault references for secrets
- Application Insights + Log Analytics with full diagnostic categories
- VNet flow logs (90-day retention) for network observability
- HTTPS-only, TLS 1.3, FTP disabled, **end-to-end TLS encryption** between
  the App Service front end and the worker (via `azapi_update_resource`)
- Zone-redundant deployment and autoscale in production
- Staging slot for blue/green swaps in `staging` and `prod`
- Tightened NSG rules (no `protocol=*` / `port=*` blanket allows)

---

## Architecture: Decoupled App & Infra Templates

The platform now separates **application code** from **infrastructure code**:

| Component | Template | Repo Naming | Role |
|-----------|----------|-------------|------|
| **App Code** | `template-helloworld-express` | `{app-name}` | Runtime: Node.js, Python, Java, etc. Owns CI/CD (build, test, deploy) |
| **Infra** | `template-terraform-azure-webapp` | `{app-name}-infra` | Infrastructure as Code: VNet, App Service, monitoring, etc. Terraform modules. |

When you provision, the platform:

1. Creates `{app-name}` from the **app template** (e.g., Node.js starter) ← app CI/CD logic
2. Creates `{app-name}-infra` from the **infra template** (Terraform) ← infrastructure provisioning
3. Runs Terraform against the infra repo to stand up Azure resources
4. Sets GitHub environment variables and federated credentials on the app repo

This **decoupling** means:

- **App teams** iterate on code without touching infrastructure
- **Infra teams** maintain reusable architecture templates (archetypes)
- **Templates are archetypes:** multiple instances (apps) can use the same archetype with different configurations

### Infrastructure Templates (Archetypes)

Each **infra template** is a self-contained Terraform module set covering an infrastructure pattern:

- **`template-terraform-azure-webapp`** (current): App Service with VNet, Private Endpoint, autoscale, observability
      - Modules: monitoring (Log Analytics), networking (VNet, NSGs, PE), webapp (App Service Plan, Web App, Managed Identity, Autoscale)
      - Environments: dev (P0v3, public), staging (P1v3, autoscale, PE-only), prod (P2v3, zone-redundant, PE-only)
      - Checkov baselines: prod-strict (mandatory HA, zone redundancy, PE-only), dev/staging-relaxed (dev allows public access for testing)

- **Future archetypes:** `template-terraform-azure-aks` (Kubernetes), `template-terraform-gcp-cloudrun` (Google Cloud), etc.

When provisioning, you specify which infra template to use as an input parameter to the `provision-infrastructure` workflow.

### State management

State is kept in Azure Storage, with one storage account per
**subscription + application** so that unrelated apps sharing a subscription
remain decoupled. The state account is AAD-auth-only — no shared keys.

Beyond the Azure side, the platform also takes care of the **application
repository**: it creates a new repo from a template you choose, configures
GitHub Environments + variables, registers the per-env OIDC federated
credentials on the platform service principal, observes the auto-triggered
CI run, and writes a per-run issue summarising plan deltas and verification
test counts.

## Architecture at a glance

```text
operator                ┌─────────────────────────────────────────────┐
  ├─ web UI (Pages) ──► │  GitHub Actions: provision-infrastructure   │
  ├─ trigger script ──► │                                             │
  └─ raw curl ────────► │   1. resolve & validate inputs              │
                        │   2. checkov scan (per env)                 │
                        │   3. terraform fmt                          │
                        │   4. bootstrap tfstate (reusable)           │
                        │   5. terraform plan (per env)               │
                        │   6. terraform apply (per env)              │
                        │   7. verify (reusable, per env)             │
                        │   8. create app repo from template          │
                        │   9. open per-run tracking issue            │
                        │  10. configure GitHub Environments + vars   │
                        │  11. register OIDC fed-creds on SP          │
                        │  12. observe CI run (first creation only)   │
                        │  13. summarise + comment on the issue       │
                        └────┬────────────────────────────────┬───────┘
                             │                                │
            OIDC, no secrets │                                │ GH_PAT
                             ▼                                ▼
      ┌──────────────────────────────────┐  ┌────────────────────────────────┐
      │ Azure subscription               │  │  GitHub: app repo              │
      │  ├── rg-tfstate-<app>            │  │   ├── from <app_template_repo> │
      │  │     └── sttf<app><sub>        │  │   ├── envs: dev/staging/prod   │
      │  │           └── tfstate/{env}/  │  │   ├── per-env variables        │
      │  └── rg-<app>-{dev|stg|prod}     │  │   ├── ci.yml — build & test &  │
      │        ├── networking + flow log │  │   │   deploy to dev triggered  │
      │        ├── monitoring (LA, AI)   │  │   │   by push on main          │
      │        └── webapp + PE + slot    │  │   ├── release.yml — deploy to  │
      │                                  │  │   │   staging/prod triggered   │
      │                                  │  │   │   by new release creation  │
      │                                  │  │   └── per-run issue + summary  │
      └──────────────────────────────────┘  └────────────────────────────────┘
```

## Repository layout

```text
.
├── .checkov.yaml                       # Checkov rules + skips for prod (strict)
├── .checkov.nonprod.yaml               # Relaxed skips for dev/staging
├── .github/workflows/
│   ├── bootstrap-tfstate.yml           # Reusable: create the tfstate storage
│   ├── verify-infrastructure.yml       # Reusable: control-plane assertions
│   └── provision-infrastructure.yml    # Main workflow: end-to-end pipeline
├── docs/                               # GitHub Pages site (Jekyll-rendered)
│   ├── _config.yml                     # Jekyll config
│   ├── index.md                        # Pages homepage (this file)
│   ├── SETUP.md                        # Full setup guide
│   ├── CONTRIBUTING.md                 # Contribution guidelines (Pages mirror)
│   ├── PAGES.md                        # Pages site info & how to enable
│   └── provision.html                  # Self-service provisioning form
├── scripts/
│   ├── bootstrap-tfstate.sh            # Idempotent az-cli bootstrap script
│   ├── verify-infra.sh                 # Control-plane verification assertions
│   ├── watch-run.sh                    # Poll a remote workflow run + outputs
│   └── trigger-provision.sh            # CLI wrapper around repository_dispatch
```

## Quick start

A full step-by-step setup (App Registration, federated credentials, RBAC,
Graph permission, GitHub Environments, GH_PAT secret) lives in the
[Setup guide](SETUP.md). At a glance:

1. Push this repo to GitHub.
2. Create the GitHub Environments `dev`, `staging`, `prod`.
3. Create an Azure App Registration and configure 4 federated credentials
   on the platform repo — one branch-scoped (`main`) and three env-scoped.
4. Grant the service principal three subscription-scoped roles
   (`Contributor`, `Storage Blob Data Contributor`, `User Access Administrator`)
   and the Graph application permission `Application.ReadWrite.OwnedBy` so it
   can manage federated credentials on the application repos it provisions.
5. Add a `GH_PAT` repo secret with `Contents`/`Administration`/`Actions`/
   `Environments`/`Variables`/`Issues` write permissions for cross-repo work.
6. Trigger the workflow — by the **[self-service web UI](provision.html)**,
   by **`scripts/trigger-provision.sh`**, or by the GitHub Actions UI / API
   directly.

## Triggering the platform

### Self-service web page (recommended)

The [provisioning form](provision.html) explains the platform, validates
inputs in-browser, shows the equivalent `curl` command for review, and
dispatches the workflow with a token the operator pastes. See
[Pages info](PAGES.md) for how the page is hosted and what token scope
the operator needs.

### CLI

```bash
scripts/trigger-provision.sh \
      --app-name               myapp \
      --environment            dev \
      --azure-subscription-id  00000000-0000-0000-0000-000000000000 \
      --azure-tenant-id        22222222-2222-2222-2222-222222222222 \
      --azure-client-id        11111111-1111-1111-1111-111111111111 \
      --infra-template-repo    your-org/template-terraform-azure-webapp \
      --app-template-repo      your-org/template-helloworld-express
```

Flags fall back to upper-case env vars (`ENVIRONMENT`, `APP_NAME`, …) and the
script auto-detects the platform repo from the current git remote. `--help`
for the full reference.

### GitHub UI

`Actions → Provision Infrastructure → Run workflow` and fill the inputs.

### Raw `repository_dispatch`

```bash
curl -X POST \
      -H "Authorization: Bearer $GH_TOKEN" \
      -H "Accept: application/vnd.github+json" \
      https://api.github.com/repos/<org>/<repo>/dispatches \
      -d '{
            "event_type": "provision-infrastructure",
            "client_payload": {
                  "app_name":               "myapp",
                  "environment":            "dev",
                  "azure_subscription_id":  "00000000-0000-0000-0000-000000000000",
                  "azure_tenant_id":        "22222222-2222-2222-2222-222222222222",
                  "azure_client_id":        "11111111-1111-1111-1111-111111111111",
                  "infra_template_repo":    "your-org/template-terraform-azure-webapp",
                  "app_template_repo":      "your-org/template-helloworld-express",
                  "container_image":        "mcr.microsoft.com/appsvc/staticsite:latest",
                  "container_registry_url": "myregistry.azurecr.io"
            }
      }'
```

The token must have `repo` scope (classic) or `Contents: write` permission
(fine-grained) on the platform repository. `Actions: write` is *not* enough
for the `repository_dispatch` endpoint.

## Conventions

- **Naming.** Most resources follow the pattern `<type>-<app>-<env>` (e.g.
  `app-myapp-dev`, `asp-myapp-prod`). Two exceptions, both driven by Azure
  Storage's 24-char globally-unique naming constraint:
  - **tfstate SA** — `sttf<app12><sub8>` (per-subscription/per-app; lives
    in `rg-tfstate-<app>`, shared by all envs of that app).
  - **VNet flow-logs SA** — `stflow<app+env>` capped at 24 chars (per-env;
    lives inside the per-env RG).
- **Tags.** Every resource is tagged with `application`, `environment`,
  `managed-by=terraform`, and `platform=platform-engineering`.
- **Secrets.** No long-lived credentials. GitHub authenticates to Azure via
  OIDC federated credentials. Application secrets must live in Key Vault and
  be referenced by name through the `key_vault_secrets` module input.
- **State.** One storage account per subscription + application. Inside it,
  one blob per environment under `tfstate/<env>/terraform.tfstate`.

## Local development

Terraform now lives in the generated `{app-name}-infra` repository (from
`infra_template_repo`). To inspect it locally, clone that repo and run checks
there. State writes should always go through CI:

```bash
git clone https://github.com/<org>/<app-name>-infra.git
cd <app-name>-infra/terraform/environments/dev
terraform fmt -check -recursive ../..
terraform init -backend=false                  # local-only, no remote state
terraform validate
```

To run Checkov locally:

```bash
pip install checkov
# Strict ruleset (matches what CI runs against prod)
checkov -d <app-name>-infra/terraform/environments/prod --framework terraform --config-file .checkov.yaml
# Relaxed ruleset (matches what CI runs against dev/staging)
checkov -d <app-name>-infra/terraform/environments/dev  --framework terraform --config-file .checkov.nonprod.yaml
```

To verify deployed infrastructure against the expected per-env policy:

```bash
APP_NAME=<app> ENVIRONMENT=<env> bash scripts/verify-infra.sh
```

## Roadmap

### Shipped

- [x] Terraform modules for Web App, networking, monitoring
- [x] GitHub Actions workflow with Checkov + plan per environment
- [x] Remote state bootstrap (idempotent, one storage account per app)
- [x] Terraform apply per environment, with `environment:` protection rules
- [x] Control-plane verification per environment (reusable workflow)
- [x] Application repository templating — new `{app-name}` repo from an app template on first run
- [x] Infrastructure repository templating — new `{app-name}-infra` repo from an infra template on first run
- [x] Workflow contract supports independent `infra_template_repo` and `app_template_repo` inputs
- [x] App repo template owns the CI, testing and deployment workflows
- [x] Infra repo template owns the Terraform code and Checkov active rules
- [x] GitHub Environments + variables on the new app repo (per env)
- [x] OIDC federated credentials registered on the platform SP per env
- [x] CI observation + per-run tracking issue + finalize comment
- [x] Template ships `ci.yml` (dev deploy) and `release.yml` (staging/prod
      promotion via a shared `deploy.yml`)
- [x] Deployment reuses the image in previous environment, applying a new tag
      to ensure that what is being tested is what is being promoted across
      environments (dev tag -> RC tag -> prod/GA tag)
- [x] Per-env compliance posture (PE-only staging/prod, public dev)
- [x] VNet flow logs + end-to-end TLS encryption (via azapi)
- [x] Tightened NSG rules (no protocol/port wildcards)
- [x] Self-service web UI on GitHub Pages
- [x] CLI trigger script (`scripts/trigger-provision.sh`)
- [x] Destroy/decommission workflow for retiring an app cleanly (delete RG +
      tfstate blob + GitHub Environments + fed-creds) -- repos are never deleted

### Next

- [ ] **Scheduled drift detection** — cron job that runs `terraform plan` on
      a schedule and posts a comment on the per-run issue if non-zero
- [ ] **Cost reporting per application** — daily / weekly Azure cost export
      aggregated by `application` tag, surfaced as a comment on the run issue
- [ ] **Budget alerts** — Azure budget per app/env with action-group
      notifications wired in
- [ ] **Container console logs in the module** — add
      `logs.application_logs.file_system_level = "Information"` so degraded
      states surface their cause without manual intervention
- [ ] **Self-hosted runner inside the VNet** — enables real HTTP smoke tests
      against PE-only staging/prod; today those rely on control-plane
      assertions only
- [ ] **Multi-region readiness** — Front Door / Traffic Manager in front of
      a primary + secondary App Service Plan, with state per region
- [ ] **Optional Key Vault module** — provisioned per env when secrets are
      declared, with the existing `key_vault_secrets` wiring already in the
      webapp module
- [ ] **Override of target environment names** — currently hardcoded
      `dev` / `staging` / `prod`; some apps need `qa`, `uat`, regional
      variants, etc.
- [ ] **Workflow input for per-env `app_settings`** — the Terraform var
      exists in the webapp module but isn't surfaced through the workflow
- [ ] **Custom domain provisioning** — module already supports it, surface
      it as a workflow input (with cert binding)
- [ ] **Template-repo pinning** — accept `infra_template_ref` and
      `app_template_ref` inputs so known tags/commits are used rather than
      the latest default branches
- [ ] **Slot-swap promotion for prod** — today the template's `release.yml`
      updates the prod container in place; switching it to deploy to the
      staging slot and swap would give zero-downtime promotion
- [ ] **Operator audit trail** — record who triggered each run (PAT
      ownership, dispatch source) on the tracking issue
- [ ] **Rollback** — add a rollback mechanism and workflow, e.g., by creating
      an issue with a special label (`urgent rollback`) to trigger it
- [ ] **Static code analysis** — add static code analysis to the CI workflow
      as a quality gate
- [ ] **Software composition analysis** — scan dependencies in libraries and
      container images for vulnerabilities as a quality gate
- [ ] **Acceptance/regression tests** — improve the test harness by adding
      e2e acceptance/regression tests (UI tests, API tests) as a quality gate
      in the release workflow: to deploy to staging e2e tests must pass in
      dev, and similarly to deploy to prod tests must pass in staging

## Contributing

See [Contributing](CONTRIBUTING.md) for development guidelines, the change
workflow, and how to propose new modules or environment policies.

## License

[MIT]({{ site.github.repository_url }}/blob/main/LICENSE) — see the license file for details.
