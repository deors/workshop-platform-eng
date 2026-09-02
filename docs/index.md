---
title:       Workshop · Platform Engineering
description: Self-service provisioning & reconciling application resources, multi-cloud, driven by GitHub Actions + Terraform.
---

<!--
Pages-rendered homepage. This file is the canonical documentation source —
the repo's top-level README.md is intentionally a short pointer to this page
and does not duplicate the content below.
-->

**📚 Quick links:**
[Self-service provisioning](provision.html) ·
[Setup: GitHub](setup-github.md) ·
[Setup: Azure](setup-azure.md) ·
[Setup: AWS](setup-aws.md) ·
[Roadmap](https://github.com/deors/workshop-platform-eng/issues) ·
[Troubleshooting](troubleshooting.md) ·
[Contributing](CONTRIBUTING.md) ·
[Pages info](pages.md) ·
[Source on GitHub]({{ site.github.repository_url }})

---

A self-service platform that provisions and reconciles application resources
across Azure, AWS and other clouds, driven by GitHub Actions and Terraform.
External systems trigger the platform through `repository_dispatch` or
`workflow_dispatch` events; the platform takes care of standing up secure,
observable, production-grade environments without the requesting team having to
write any infrastructure code.

The platform supports two operating modes in a single workflow:

- **Full mode** (infra + app) — provisions cloud resources *and* bootstraps the
  application repository (GitHub Environments, variables, OIDC trust,
  CI observation).
- **Infra-only mode** — provisions cloud resources only (Landing Zones,
  foundational platform components, shared services). The application repository
  phase is skipped entirely. Activated by leaving `app_template_repo` empty.

> **Status:** functional end-to-end. Plan → apply → verify, application repo
> creation from template, GitHub Environments + variables, OIDC federated
> credentials, CI observation and per-run tracking issue are all wired. See
> [Roadmap](https://github.com/deors/workshop-platform-eng/issues) for what's next.

---

## What this platform does

Given an existing cloud account, the platform provisions an opinionated
container stack for an application across three environments — `dev`,
`staging`, `prod` — following each cloud's well-architected guidance for
security, observability and connectivity.

Whatever the target, every environment comes out with the same properties:

- **Private by default** — public reachability is a per-environment decision,
  with `dev` open for smoke tests and `staging`/`prod` locked down
- **No long-lived credentials** — a platform identity federated to GitHub via
  OIDC, and a workload identity for the app itself
- **Observability wired in** — centralised logs, metrics and traces, with
  network-level flow logs retained for auditing
- **HTTPS-only, TLS 1.3**, with certificates issued and renewed automatically
- **Resilient in production** — multi-zone placement and autoscaling
- **Zero-downtime releases** — blue/green or slot-based swaps
- **Least-privilege networking** — no blanket allow rules

The concrete services differ per cloud. Each archetype documents its own
stack:

| Cloud | Stack | Provision | Setup |
|-------|-------|-----------|-------|
| **Azure** | App Service (Linux, container) with VNet integration, Private Endpoint, Managed Identity, Key Vault references, Application Insights + Log Analytics, deployment slots | [form](provision-azure.html) | [guide](setup-azure.md) |
| **AWS** | ECS Fargate behind an Application Load Balancer, with VPC + NAT, ACM certificates, CloudWatch logs and alarms, X-Ray, CodeDeploy blue/green | [form](provision-aws.html) | [guide](setup-aws.md) |

The GitHub side of the setup is [identical for every
cloud](setup-github.md) — do that once, then follow the guide for your target.

---

## Architecture: Decoupled App & Infra Templates

The platform separates **application code** from **infrastructure code**, and
the application phase is entirely optional:

| Component                 | Template                           | Repo naming         | Role                                                                                           |
|---------------------------|------------------------------------|---------------------|------------------------------------------------------------------------------------------------|
| **Infra**                 | one `template-terraform-*` archetype | `{app-name}-infra`  | IaC: networking, compute, monitoring, etc. Terraform modules. Always runs.                     |
| **App Code** *(optional)* | `template-helloworld-express`      | `{app-name}`        | Runtime: Node.js, Python, Java, etc. Owns CI/CD. Runs only when `app_template_repo` is set.    |

When `app_template_repo` is provided (full mode), the platform:

1. Creates `{app-name}-infra` from the **infra template** (Terraform) ← infrastructure provisioning
2. Runs Terraform against the infra repo to stand up the cloud resources
3. Creates `{app-name}` from the **app template** (e.g., Node.js starter) ← app CI/CD logic
4. Sets GitHub environment variables and federated credentials on the app repo

When `app_template_repo` is omitted (infra-only mode), steps 3 and 4 are
skipped — useful for Landing Zones, foundational platform components, or any
scenario where application code is managed separately.

This **decoupling** means:

- **App teams** iterate on code without touching infrastructure
- **Infra teams** maintain reusable architecture templates (archetypes)
- **Platform teams** can provision pure infra components without coupling them to an app repo
- **Templates are archetypes:** multiple instances (apps) can use the same archetype with different configurations

### Infrastructure Templates (Archetypes)

Each **infra template** is a self-contained Terraform module set covering an infrastructure pattern:

- **`template-terraform-azure-webapp`**: App Service with VNet, Private Endpoint, autoscale, observability
      - Modules: monitoring (Log Analytics), networking (VNet, NSGs, PE), webapp (App Service Plan, Web App, Managed Identity, Autoscale)
      - Environments: dev (P0v3, public), staging (P1v3, autoscale, PE-only), prod (P2v3, zone-redundant, PE-only)

- **`template-terraform-aws-fargate`**: ECS Fargate behind an ALB, with certificates and blue/green deployments
      - Modules: monitoring (CloudWatch, X-Ray), networking (VPC, subnets, NAT, ALB, ACM), webapp (ECS cluster/service, task roles, autoscaling)
      - Environments: dev (public ALB), staging and prod (internal, autoscaled)

- **Future archetypes:** `template-terraform-gcp-cloudrun` (Google Cloud), etc.

Each archetype ships its own Checkov baselines — strict for prod (mandatory HA
and private networking), relaxed for dev/staging — and its own `scripts/verify.sh`.

When provisioning, you specify which infra template to use as an input
parameter, which is what selects the target architecture.

### State management

State lives in the target cloud's own object storage, with one backend per
**account + application** so that unrelated apps sharing an account remain
decoupled, and one state object per environment inside it. The platform
bootstraps that backend itself — it is a platform concern, not something each
template re-implements — and hardens it the same way everywhere: versioned,
encrypted at rest, private, and reachable only over TLS.

| Cloud | Backend | Identity model |
|-------|---------|----------------|
| **Azure** | Storage account `sttf<app12><sub8>`, container `tfstate` | AAD-auth only — no shared keys |
| **AWS** | S3 bucket `tf-state-<app>-<account8>` | IAM via OIDC role assumption |

Beyond the cloud side, the platform also takes care of the **application
repository**: it creates a new repo from a template you choose, configures
GitHub Environments + variables, registers the per-env OIDC federated
credentials on the platform service principal, observes the auto-triggered
CI run, and writes a per-run issue summarising plan deltas and verification
test counts.

## Architecture at a glance

```text
operator                ┌─────────────────────────────────────────────┐
  ├─ web UI (Pages) ──► │  GitHub Actions: <cloud> - Provision &      │
  ├─ trigger script ──► │                  Reconcile App Resources    │
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
      │ cloud account                    │  │  GitHub: app repo              │
      │  ├── state backend, per app      │  │   ├── from <app_template_repo> │
      │  │     └── one object per env    │  │   ├── envs: dev/staging/prod   │
      │  │           tfstate/{env}/      │  │   ├── per-env variables        │
      │  └── one group per environment   │  │   ├── ci.yml — build & test &  │
      │        ├── networking + flow log │  │   │   deploy to dev triggered  │
      │        ├── monitoring + tracing  │  │   │   by push on main          │
      │        └── compute + ingress     │  │   ├── release.yml — deploy to  │
      │                                  │  │   │   staging/prod triggered   │
      │                                  │  │   │   by new release creation  │
      │                                  │  │   └── per-run issue + summary  │
      └──────────────────────────────────┘  └────────────────────────────────┘
```

## Repository layout

```text
.
├── .checkov.nonprod.yaml                    # Relaxed skips for dev/staging
├── .checkov.yaml                            # Checkov rules + skips for prod (strict)
├── .github/workflows/                       # one file per cloud; names are prefixed "Azure - " / "AWS - "
│   ├── bootstrap-tfstate.yml                # Reusable: create the state backend in Azure
│   ├── bootstrap-tfstate-aws.yml            #   └── AWS counterpart
│   ├── delete-app-resources-all.yml         # Manual: delete every env + state for an app in Azure
│   ├── delete-app-resources-all-aws.yml.    #   └── AWS counterpart
│   ├── delete-app-resources-single.yml      # Manual/callable: delete one environment in Azure
│   ├── delete-app-resources-single-aws.yml. #   └── AWS counterpart
│   ├── delete-resource-group.yml            # Reusable: delete a single resource group in Azure
│   ├── delete-resource-group-aws.yml        #   └── AWS counterpart
│   ├── detect-drift.yml                     # Scheduled/callable: read-only drift sweep in Azure
│   ├── detect-drift-aws.yml                 #   └── AWS counterpart
│   ├── provision-infrastructure.yml         # Main workflow: end-to-end pipeline in Azure
│   ├── provision-infrastructure-aws.yml     #   └── AWS counterpart
│   ├── tag-app-resources.yml                # Manual: merge compliance tags onto all app resources in Azure
│   ├── tag-app-resources-aws.yml            #   └── AWS counterpart
│   ├── verify-infrastructure.yml            # Reusable: runs the infra repo's verify script in Azure
│   └── verify-infrastructure-aws.yml        #   └── AWS counterpart
├── docs/                                    # GitHub Pages site (Jekyll-rendered)
│   ├── _config.yml                          # Jekyll config
│   ├── CONTRIBUTING.md                      # Contribution guidelines (Pages mirror)
│   ├── index.md                             # Pages homepage (this file)
│   ├── pages.md                             # Pages site map & how to enable
│   ├── provision.html                       # Provisioning entry point — picks a cloud
│   ├── provision-azure.html                 # Self-service provisioning form (Azure)
│   ├── provision-aws.html                   # Self-service provisioning form (AWS)
│   ├── setup-github.md                      # One-time GitHub setup (every cloud)
│   ├── setup-azure.md                       # One-time Azure setup
│   └── troubleshooting.md                   # GitHub/Actions, tfstate & cloud-login issues
├── scripts/                                 # cloud-specific scripts carry an -azure / -aws suffix
│   ├── bootstrap-tfstate-azure.sh           # Idempotent az-cli state bootstrap (storage account)
│   ├── bootstrap-tfstate-aws.sh             # Idempotent aws-cli state bootstrap (S3 bucket)
│   ├── preflight-inputs.sh                  # Existence checks for template repos + container image (cloud-agnostic)
│   ├── tag-app-resources-azure.sh           # Merge an arbitrary tag set onto all app resources
│   ├── tag-app-resources-aws.sh             # Same, via the Resource Groups Tagging API
│   ├── trigger-provision-azure.sh           # CLI wrapper around repository_dispatch
│   ├── trigger-provision-aws.sh             # Same, for the AWS workflow
│   └── watch-run.sh                         # Poll a remote workflow run + outputs (cloud-agnostic)
```

> Control-plane verification is no longer defined here. It lives in each infra
> template at the canonical path `scripts/verify.sh`, so the orchestrator stays
> template-agnostic — `verify-infrastructure.yml` checks out the provisioned
> infra repo and runs that script.

## Quick start

Setup is two guides: the GitHub part, identical for every cloud, then the part
for the cloud you're targeting. At a glance:

1. **[Setup for GitHub](setup-github.md)** — push this repo, create the
   `dev` / `staging` / `prod` Environments, add the `GH_PAT` secret for
   cross-repo work.
2. **Setup for your cloud** — [Azure](setup-azure.md) or [AWS](setup-aws.md):
   create the platform identity, federate it to GitHub via OIDC so no secrets
   are stored, and grant it the least privilege needed to bootstrap state and
   plan changes.
3. **Trigger a run** — via the **[self-service web UI](provision.html)**, a
   CLI wrapper (`scripts/trigger-provision-azure.sh` /
   `scripts/trigger-provision-aws.sh`), or the GitHub Actions UI / API
   directly.

The state backend itself needs no manual setup: the platform bootstraps it on
first run and every run thereafter, idempotently.

## Triggering the platform

### Self-service web page (recommended)

The [provisioning page](provision.html) explains how a run works and hands off
to a per-cloud form. Each form validates inputs in-browser, shows the
equivalent `curl` command for review, and dispatches the workflow with a token
the operator pastes. See [Pages info](pages.md) for how the pages are hosted
and what token scope the operator needs.

### CLI

One wrapper per cloud, each building that cloud's `repository_dispatch`
payload. For Azure:

```bash
scripts/trigger-provision-azure.sh \
      --app-name               myapp \
      --environment            dev \
      --azure-tenant-id        $AZURE_TENANT_ID \
      --azure-subscription-id  $AZURE_SUBSCRIPTION_ID \
      --azure-client-id        $AZURE_CLIENT_ID \
      --azure-location         westeurope \
      --infra-template-repo    your-org/template-terraform-azure-webapp \
      --app-template-repo      your-org/template-helloworld-express \
      --container-image        your-org/template-helloworld-express:sha-af53b68
```

For AWS:

```bash
scripts/trigger-provision-aws.sh \
      --app-name            myapp \
      --environment         dev \
      --aws-region          eu-west-1 \
      --aws-role-arn        arn:aws:iam::$AWS_ACCOUNT_ID:role/GitHubActionsRole \
      --main-domain         example.com \
      --infra-template-repo your-org/template-terraform-aws-fargate \
      --app-template-repo   your-org/template-helloworld-express \
      --container-image     your-org/template-helloworld-express:sha-af53b68
```

Flags fall back to upper-case env vars (`ENVIRONMENT`, `APP_NAME`, …) and the
scripts auto-detect the platform repo from the current git remote. `--help`
for the full reference.

The target-cloud parameters (`--azure-tenant-id` / `--azure-subscription-id`
/ `--azure-client-id` / `--azure-location`, and `--aws-region` /
`--aws-role-arn`) are optional when the platform repository carries the
`PROVISION_*` organization defaults — set once, per the *Lock in the target
cloud* section of each setup guide. A flag always overrides the variable;
with neither, the run fails fast naming both ways to supply the value.

### GitHub UI

`Actions → <cloud> - Provision & Reconcile Application Resources → Run workflow`
and fill the inputs. Every workflow name is prefixed with its cloud, so the
Azure and AWS pipelines sit side by side in the Actions list.

### Raw `repository_dispatch`

The `event_type` selects the cloud — for example,
`azure-provision-infrastructure` in the case of Azure. The payload carries that
cloud's identity and region parameters — or omits them, when the repository
carries the `PROVISION_*` organization defaults (an explicit key always
overrides the variable):

```bash
curl -X POST \
      -H "Authorization: Bearer $GH_TOKEN" \
      -H "Accept: application/vnd.github+json" \
      https://api.github.com/repos/<org>/<repo>/dispatches \
      -d '{
            "event_type": "azure-provision-infrastructure",
            "client_payload": {
                  "app_name":               "myapp",
                  "environment":            "dev",
                  "azure_tenant_id":        "$AZURE_TENANT_ID",
                  "azure_subscription_id":  "$AZURE_SUBSCRIPTION_ID",
                  "azure_client_id":        "$AZURE_CLIENT_ID",
                  "azure_location":         "westeurope",
                  "infra_template_repo":    "your-org/template-terraform-azure-webapp",
                  "infra_template_ref":     "main",
                  "app_template_repo":      "your-org/template-helloworld-express",
                  "app_template_ref":       "main",
                  "container_image":        "your-org/template-helloworld-express:sha-af53b68",
                  "container_registry_url": "ghcr.io"
            }
      }'
```

And the AWS equivalent:

```bash
curl -X POST \
      -H "Authorization: Bearer $GH_TOKEN" \
      -H "Accept: application/vnd.github+json" \
      https://api.github.com/repos/<org>/<repo>/dispatches \
      -d '{
            "event_type": "aws-provision-infrastructure",
            "client_payload": {
                  "app_name":            "myapp",
                  "environment":         "dev",
                  "aws_role_arn":        "arn:aws:iam::$AWS_ACCOUNT_ID:role/GitHubActionsRole",
                  "aws_region":          "eu-west-1",
                  "main_domain":         "example.com",
                  "infra_template_repo": "your-org/template-terraform-aws-fargate",
                  "infra_template_ref":  "main",
                  "app_template_repo":   "your-org/template-helloworld-express",
                  "app_template_ref":    "main",
                  "container_image":     "your-org/template-helloworld-express:sha-af53b68"
            }
      }'
```

The token must have `repo` scope (classic) or `Contents: write` permission
(fine-grained) on the platform repository. `Actions: write` is *not* enough
for the `repository_dispatch` endpoint.

## Compliance tagging

The `tag-app-resources-<cloud>.yml` workflows merge an arbitrary set of tags onto every
resource that belongs to an app — `tag-app-resources.yml` for Azure,
`tag-app-resources-aws.yml` for AWS. It is a **day-2 operation** — run it any
time after resources exist to back-fill governance metadata, adopt a new tagging
standard, or correct values without reprovisioning.

### What it tags

The workflow discovers all resource groups for the app and tags each group and
every resource inside it:

| Resource group pattern | Purpose |
| --- | --- |
| `rg-<app_name>-dev` / `staging` / `prod` | Per-environment application resources |
| `rg-<app_name>-tfstate` | Terraform state backend |

Tags are **merged** — existing tags not present in `tags_json` are left
unchanged. Re-running the workflow with updated values is safe.

> **On AWS**, a resource group is a saved tag query rather than a container, so
> the workflow resolves each group's query and tags the resources it matches.
> The group names and the merge semantics are the same.

### Inputs

Three inputs are the same on every cloud; the rest are that cloud's identity
and region parameters:

| Input | Required | Description |
| --- | --- | --- |
| `app_name` | Yes | Application name — used to discover resource groups |
| `tags_json` | Yes | JSON object whose keys/values become the tags, e.g. `{"airid":"309005","Application":"myapp","CreatedBy":"user"}` |
| `dry_run` | No (default: `false`) | When `true`, discovers and lists all resources that would be tagged without writing anything |
| *cloud credentials* | Yes | Azure: `azure_tenant_id`, `azure_subscription_id`, `azure_client_id`. AWS: `aws_region`, `aws_role_arn` |

### How to run

`Actions → <cloud> - Tag Application Resources → Run workflow`, fill the form, and paste
the JSON tags object. Use `dry_run: true` first to preview the full scope — the
step summary shows the tag list and the run log shows every resource that would
be tagged.

The workflow authenticates via OIDC using the same identity the provisioning
workflow uses — no client secret or access key is required.

### Running locally

The underlying script can also be run directly against an authenticated CLI
session. For Azure:

```bash
scripts/tag-app-resources-azure.sh \
  --app-name               myapp \
  --azure-tenant-id        $AZURE_TENANT_ID \
  --azure-subscription-id  $AZURE_SUBSCRIPTION_ID \
  --azure-client-id        $AZURE_CLIENT_ID \
  --tags-json              '{"tag1":"value1","tag2":"value2","CreatedBy":"user"}' \
  --dry-run
```

For AWS, with credentials already configured:

```bash
scripts/tag-app-resources-aws.sh \
  --app-name   myapp \
  --aws-region eu-west-1 \
  --tags-json  '{"tag1":"value1","tag2":"value2","CreatedBy":"user"}' \
  --dry-run
```

Remove `--dry-run` to apply. Both require `jq` plus that cloud's CLI.

---

## Conventions

These hold across clouds; where a cloud forces an exception it is called out.

- **Naming.** Resources follow `<type>-<app>-<env>`, and resource groups
  `rg-<app>-<env>` plus `rg-<app>-tfstate`. Exceptions arise only where a
  provider imposes a stricter namespace — globally-unique storage names, for
  instance — and each archetype documents its own.
- **Tags.** Every resource carries `application`, `environment`,
  `managed-by=terraform`, and `platform=platform-engineering`. On AWS these
  double as the resource-group query; on Azure they are plain metadata.
- **Secrets.** No long-lived credentials anywhere. GitHub authenticates to the
  cloud via OIDC, and the application uses a workload identity — an Azure
  Managed Identity, an AWS task role. Application secrets belong in the cloud's
  own secret store and are referenced by name, never inlined.
- **Regions.** Always an explicit, required input. No workflow or script
  defaults a region: an implicit one silently deploys somewhere nobody expects.
- **State.** One backend per account + application, one state object per
  environment under `<env>/terraform.tfstate`.

## Local development

Terraform now lives in the generated `{app-name}-infra` repository (from
`infra_template_repo`). To inspect it locally, clone that repo and run checks
there. State writes should always go through CI.

```bash
git clone https://github.com/<org>/<app-name>-infra.git
cd <app-name>-infra/
```

The generated infra repository includes a detailed, step-by-step guide in its
own documentation that explains how to configure the tools, run the Checkov
checks, create and apply plans locally, validate changes, to be able to evolve
the infrastructure when new requirements arise.

## Roadmap

See the [issue tracker](https://github.com/deors/workshop-platform-eng/issues) for the current and planned features.

## Contributing

See [Contributing](CONTRIBUTING.md) for development guidelines, the change
workflow, and how to propose new modules or environment policies.

## License

[MIT]({{ site.github.repository_url }}/blob/main/LICENSE) — see the license file for details.
