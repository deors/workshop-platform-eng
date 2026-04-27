# Workshop · Platform Engineering

A self-service platform that provisions Azure infrastructure for containerised
web applications, driven by GitHub Actions and Terraform. External systems
trigger the platform through `repository_dispatch` or `workflow_dispatch` events;
the platform takes care of standing up secure, observable, production-grade
environments without the requesting team having to write any infrastructure code.

> **Status:** early scaffold. The first milestone (Terraform code + CI plan
> pipeline + remote state bootstrap) is in place. Apply, repository
> templating, and deployment wiring are still to come — see [Roadmap](#roadmap).

---

## What this platform does

Given an existing Azure subscription, the platform provisions an opinionated
**Azure App Service (Linux, container)** stack for an application across three
environments — `dev`, `staging`, `prod` — following Microsoft's well-architected
guidance for security, observability, and connectivity:

- VNet integration for outbound traffic, Private Endpoint for inbound
- User-assigned Managed Identity (no credentials in app settings)
- Key Vault references for secrets
- Application Insights + Log Analytics with full diagnostic categories
- HTTPS-only, TLS 1.3, FTP disabled
- Zone-redundant deployment and autoscale in production
- Staging slot for blue/green swaps in `staging` and `prod`

State is kept in Azure Storage, with one storage account per
**subscription + application** so that unrelated apps sharing a subscription
remain decoupled.

## Architecture at a glance

```
                    ┌──────────────────────────────────────┐
external system ──► │  GitHub Actions: provision workflow  │
(workflow_dispatch  │   1. resolve & validate inputs       │
 or repository_     │   2. checkov scan                    │
 dispatch)          │   3. terraform fmt                   │
                    │   4. bootstrap tfstate (idempotent)  │
                    │   5. terraform init/validate/plan    │
                    └──────────────────┬───────────────────┘
                                       │
                                       ▼  (OIDC, no secrets)
                    ┌──────────────────────────────────────┐
                    │  Azure subscription                  │
                    │   ├── rg-tfstate-<app>               │
                    │   │     └── sttf<app><sub>           │
                    │   │           └── tfstate/           │
                    │   │                 ├── dev/         │
                    │   │                 ├── staging/     │
                    │   │                 └── prod/        │
                    │   ├── rg-<app>-dev                   │
                    │   ├── rg-<app>-staging               │
                    │   └── rg-<app>-prod                  │
                    └──────────────────────────────────────┘
```

## Repository layout

```
.
├── .checkov.yaml                       # Checkov rules and skips (justified)
├── .github/workflows/
│   ├── bootstrap-tfstate.yml           # Standalone: create the tfstate storage
│   └── provision-infrastructure.yml    # Main workflow: scan + plan per env
├── scripts/
│   └── bootstrap-tfstate.sh            # Idempotent az-cli bootstrap script
└── terraform/
    ├── modules/
    │   ├── webapp/                     # Web App + Plan + Identity + PE + …
    │   ├── networking/                 # VNet, subnets, NSGs, Private DNS
    │   └── monitoring/                 # Log Analytics workspace
    └── environments/
        ├── dev/                        # P0v3, no zone redundancy
        ├── staging/                    # P1v3, autoscale, staging slot
        └── prod/                       # P2v3, zone-redundant, autoscale, slot
```

## Quick start

A full step-by-step setup (App Registration, federated credentials, RBAC,
GitHub Environments) lives in [`docs/SETUP.md`](docs/SETUP.md). At a glance:

1. Push this repo to GitHub.
2. Create the GitHub Environments `dev`, `staging`, `prod`.
3. Create an Azure App Registration and configure 4 federated credentials —
   one per branch (`main`) and one per environment.
4. Assign the service principal `Contributor`, `Storage Blob Data Contributor`,
   and `User Access Administrator` at subscription scope.
5. Run **Actions → Provision Infrastructure → Run workflow** with the
   `app_name`, `subscription_id`, `azure_client_id`, `azure_tenant_id`, and
   `container_image` inputs.

## Triggering the platform

### From GitHub UI

`Actions → Provision Infrastructure → Run workflow` with the inputs documented
in the workflow file.

### From an external system (`repository_dispatch`)

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
      "container_image":        "myregistry.azurecr.io/myapp:1.0.0",
      "container_registry_url": "myregistry.azurecr.io"
    }
  }'
```

The token must have `repo` scope (classic) or `actions: write` permission
(fine-grained) on the target repository.

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
cp terraform.tfvars.example terraform.tfvars   # edit with your values
terraform fmt -check -recursive ../..
terraform init -backend=false                  # local-only, no remote state
terraform validate
```

To run Checkov locally:

```bash
pip install checkov
checkov --directory terraform/ --framework terraform --config-file .checkov.yaml
```

## Roadmap

- [x] Terraform modules for Web App, networking, monitoring
- [x] GitHub Actions workflow with Checkov + plan per environment
- [x] Remote state bootstrap (idempotent, one storage account per app)
- [ ] Apply step with environment protection rules
- [ ] Repository templating: create a new app repo from a template on first
      provision, wire up its CI/CD to the freshly created environments
- [ ] Drift detection on a schedule
- [ ] Cost reporting per application
- [ ] Allow override of target environment names
- [ ] Allow override of Web App settings per environment

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development guidelines, the change
workflow, and how to propose new modules or environment policies.

## License

[MIT](LICENSE) — see the license file for details.
