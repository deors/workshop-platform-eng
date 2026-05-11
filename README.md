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

```
operator                ┌─────────────────────────────────────────────┐
  ├─ web UI (Pages) ──► │  GitHub Actions: provision-infrastructure   │
  ├─ trigger script ─►  │                                             │
  └─ raw curl ──────►   │   1. resolve & validate inputs              │
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
              OIDC, no secrets│                                │GH_PAT
                             ▼                                ▼
        ┌──────────────────────────────────┐    ┌────────────────────────────┐
        │ Azure subscription               │    │  GitHub: app repo          │
        │  ├── rg-tfstate-<app>            │    │   ├── from <template_repo> │
        │  │     └── sttf<app><sub>        │    │   ├── envs: dev/stg/prod   │
        │  │           └── tfstate/{env}/  │    │   ├── per-env variables    │
        │  └── rg-<app>-{dev|stg|prod}     │    │   ├── auto-triggered CI    │
        │        ├── networking + flow log │    │   └── per-run issue +      │
        │        ├── monitoring (LA, AI)   │    │       summary comment      │
        │        └── webapp + PE + slot    │    └────────────────────────────┘
        └──────────────────────────────────┘
```

## Repository layout

```
.
├── .checkov.yaml                       # Checkov rules + skips for prod (strict)
├── .checkov.nonprod.yaml               # Relaxed skips for dev/staging
├── .github/workflows/
│   ├── bootstrap-tfstate.yml           # Reusable: create the tfstate storage
│   ├── verify-infrastructure.yml       # Reusable: control-plane assertions
│   └── provision-infrastructure.yml    # Main workflow: end-to-end pipeline
├── docs/
│   ├── index.html                      # Self-service web UI (GitHub Pages)
│   ├── PAGES.md                        # How to enable Pages on this repo
│   ├── SETUP.md                        # Full setup guide
│   └── .nojekyll                       # Bypass Jekyll
├── scripts/
│   ├── bootstrap-tfstate.sh            # Idempotent az-cli bootstrap script
│   ├── verify-infra.sh                 # Control-plane verification assertions
│   ├── watch-run.sh                    # Poll a remote workflow run + outputs
│   └── trigger-provision.sh            # CLI wrapper around repository_dispatch
└── terraform/
    ├── modules/
    │   ├── webapp/                     # Web App + Plan + Identity + PE + slot
    │   │                               #   + end-to-end TLS via azapi
    │   ├── networking/                 # VNet, subnets, NSGs, Private DNS,
    │   │                               #   VNet flow logs (+ logs SA)
    │   └── monitoring/                 # Log Analytics workspace
    └── environments/
        ├── dev/                        # P0v3, no zone redundancy, public on
        ├── staging/                    # P1v3, autoscale, slot, PE-only
        └── prod/                       # P2v3, zone-redundant, autoscale, slot, PE-only
```

## Quick start

A full step-by-step setup (App Registration, federated credentials, RBAC,
Graph permission, GitHub Environments, GH_PAT secret) lives in
[`docs/SETUP.md`](docs/SETUP.md). At a glance:

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
6. Trigger the workflow — by the **web UI** (`https://<owner>.github.io/<repo>/`,
   see [docs/PAGES.md](docs/PAGES.md)), by **`scripts/trigger-provision.sh`**, or
   by the GitHub Actions UI / API directly.

## Triggering the platform

### Self-service web page (recommended)

`https://<owner>.github.io/<repo>/` — once GitHub Pages is enabled on this
repo. The page explains the platform, validates inputs in-browser, shows
the equivalent `curl` command for review, and dispatches the workflow with
a token the operator pastes. See [docs/PAGES.md](docs/PAGES.md).

### CLI

```bash
scripts/trigger-provision.sh \
  --environment      dev \
  --app-name         myapp \
  --subscription-id  00000000-0000-0000-0000-000000000000 \
  --azure-client-id  11111111-1111-1111-1111-111111111111 \
  --azure-tenant-id  22222222-2222-2222-2222-222222222222 \
  --template-repo    your-org/template-app
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
      "environment":            "dev",
      "app_name":               "myapp",
      "subscription_id":        "00000000-0000-0000-0000-000000000000",
      "azure_client_id":        "11111111-1111-1111-1111-111111111111",
      "azure_tenant_id":        "22222222-2222-2222-2222-222222222222",
      "template_repo":          "your-org/template-app",
      "container_image":        "myregistry.azurecr.io/myapp:1.0.0",
      "container_registry_url": "myregistry.azurecr.io"
    }
  }'
```

The token must have `repo` scope (classic) or `Contents: write` permission
(fine-grained) on the platform repository. `Actions: write` is *not* enough
for the `repository_dispatch` endpoint.

## Conventions

- **Naming.** All resources follow the pattern `<type>-<app>-<env>` (e.g.
  `app-myapp-dev`, `asp-myapp-prod`). The state storage account uses
  `sttf<app12><sub8>` to fit Azure's 24-char globally-unique constraint.
- **Tags.** Every resource is tagged with `application`, `environment`,
  `managed-by=terraform`, and `platform=platform-engineering`.
- **Secrets.** No long-lived credentials. GitHub authenticates to Azure via
  OIDC federated credentials. Application secrets must live in Key Vault and
  be referenced by name through the `key_vault_secrets` module input.
- **State.** One storage account per subscription + application. Inside it,
  one blob per environment under `tfstate/<env>/terraform.tfstate`.

## Local development

The Terraform code can be planned locally for inspection — but state writes
should always go through CI:

```bash
cd terraform/environments/dev
terraform fmt -check -recursive ../..
terraform init -backend=false                  # local-only, no remote state
terraform validate
```

To run Checkov locally:

```bash
pip install checkov
# Strict ruleset (matches what CI runs against prod)
checkov -d terraform/environments/prod --framework terraform --config-file .checkov.yaml
# Relaxed ruleset (matches what CI runs against dev/staging)
checkov -d terraform/environments/dev  --framework terraform --config-file .checkov.nonprod.yaml
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
- [x] Repository templating — new app repo from a template on first run
- [x] GitHub Environments + variables on the new app repo (per env)
- [x] OIDC federated credentials registered on the platform SP per env
- [x] CI observation + per-run tracking issue + finalize comment
- [x] Template ships `ci.yml` (dev deploy) and `release.yml` (staging/prod
      promotion via a shared `deploy.yml`)
- [x] Per-env compliance posture (PE-only staging/prod, public dev)
- [x] VNet flow logs + end-to-end TLS encryption (via azapi)
- [x] Tightened NSG rules (no protocol/port wildcards)
- [x] Self-service web UI on GitHub Pages
- [x] CLI trigger script (`scripts/trigger-provision.sh`)

### Next

- [ ] **Lifecycle commands** — destroy/decommission workflow for retiring an
      app cleanly (delete RG + tfstate blob + GitHub Environments + fed-creds)
- [ ] **Scheduled drift detection** — cron job that runs `terraform plan` on
      a schedule and posts a comment on the per-run issue if non-zero
- [ ] **Cost reporting per application** — daily / weekly Azure cost export
      aggregated by `application` tag, surfaced as a comment on the run issue
- [ ] **Container console logs in the module** — add
      `logs.application_logs.file_system_level = "Information"` so degraded
      states surface their cause without manual intervention
- [ ] **Self-hosted runner inside the VNet** — enables real HTTP smoke tests
      against PE-only staging/prod; today those rely on control-plane
      assertions only
- [ ] **Multi-region readiness** — Front Door / Traffic Manager in front of
      a primary + secondary App Service Plan, with state per region
- [ ] **Budget alerts** — Azure budget per app/env with action-group
      notifications wired in
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
- [ ] **Template-repo pinning** — accept a `template_ref` input so a known
      template tag/commit is used rather than the latest default branch
- [ ] **Slot-swap promotion for prod** — today the template's `release.yml`
      updates the prod container in place; switching it to deploy to the
      staging slot and swap would give zero-downtime promotion
- [ ] **Operator audit trail** — record who triggered each run (PAT
      ownership, dispatch source) on the tracking issue

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development guidelines, the change
workflow, and how to propose new modules or environment policies.

## License

[MIT](LICENSE) — see the license file for details.
