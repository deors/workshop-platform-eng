---
title: Workshop Roadmap
---

[← back to home](index.md)

## Shipped

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
- [x] Per-env compliance posture (private staging/prod, public dev)
- [x] Network flow logs + end-to-end TLS encryption *(Azure archetype)*
- [x] Tightened network rules (no protocol/port wildcards)
- [x] Self-service web UI on GitHub Pages
- [x] CLI trigger script (`scripts/trigger-provision-<cloud>.sh`)
- [x] Destroy/decommission workflow for retiring an app cleanly (delete
      resources + state + GitHub Environments + OIDC trust) -- repos are never deleted
- [x] Scheduled drift detection — weekly (also on-demand and callable)
      `terraform plan -refresh-only` sweep that compares recorded state against
      live resources for one or more apps (matrix) and opens an issue
      with the per-environment findings when drift or an error is detected
- [x] Compliance tagging workflow — manually triggered, merges an arbitrary
      JSON tag set onto every resource group and resource belonging to an app
      (env groups + tfstate group), with dry-run preview support
- [x] Infra-only mode — application repository phase is fully optional; omitting
      `app_template_repo` skips all app-repo jobs (repo creation, GitHub
      Environments, federated credentials, CI observation) so the workflow can
      be used for Landing Zones and foundational platform components with no
      application coupling
- [x] **Template-repo pinning** — accept `infra_template_ref` and
      `app_template_ref` inputs so known tags/commits are used rather than
      the latest default branches
- [x] **AWS parity** — the ECS Fargate archetype's provisioning workflow and
      its [`provision-aws.html`](provision-aws.html) form are in place, and
      bootstrap, verify, drift, tagging and decommission all have AWS
      counterparts

## Next

### Platform-wide

- [ ] **Cost reporting per application** — daily / weekly cost export
      aggregated by `application` tag, surfaced as a comment on the run issue
- [ ] **Budget alerts** — a per app/env budget with notifications wired in
- [ ] **Self-hosted runner inside the private network** — enables real HTTP
      smoke tests against private staging/prod; today those rely on
      control-plane assertions only
- [ ] **Multi-region readiness** — a global entry point in front of a primary
      and secondary deployment, with state per region
- [ ] **Decouple environment variables from the orchestrator** — the names and
      values of environment variables to be configured on an application should
      be owned by the archetype (infra/app templates, as one provides and the
      other consumes), not passed through the orchestrator; the orchestrator
      should not need to know the app's variable contract for each archetype,
      and should not need to be updated when a new archetype is added or an
      existing one changes its variable contract
- [ ] **Optional secret-store module** — provisioned per env when secrets are
      declared
- [ ] **Override of target environment names** — currently hardcoded
      `dev` / `staging` / `prod`; some apps need `qa`, `uat`, regional
      variants, etc.
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
- [ ] **Move workflows to OpenTofu** — CI currently runs `terraform` via
      `hashicorp/setup-terraform` (`~1.9`) while local development uses
      OpenTofu (`tofu`), so the two toolchains can drift. Switch the
      workflows to `opentofu/setup-opentofu` and `tofu` commands across all
      provisioning, verification, drift-detection, and teardown workflows,
      keeping the version pin and `wrapper: false` behavior equivalent

### Azure archetype

- [ ] **Container console logs in the module** — add
      `logs.application_logs.file_system_level = "Information"` so degraded
      states surface their cause without manual intervention
- [ ] **Slot-swap promotion for prod** — today the template's `release.yml`
      updates the prod container in place; switching it to deploy to the
      staging slot and swap would give zero-downtime promotion
- [ ] **Workflow input for per-env `app_settings`** — the Terraform var
      exists in the webapp module but isn't surfaced through the workflow
- [ ] **Private registry credentials without platform custody** — the template
      accepts `container_registry_username` / `container_registry_password` for
      private non-ACR registries, but surfacing them through the platform puts
      a secret in the `tfplan` artifact and on the run page. The Key Vault
      approach needs a spike before anything is built

### AWS archetype

- [ ] **Private registry support (non-ECR)** — the Fargate template pulls from
      same-account ECR (task execution role) and public registries only; the
      task definition carries no `repositoryCredentials` by design, so private
      Docker Hub / GHCR images cannot be used without mirroring into ECR. Add
      optional support the AWS-native way: an operator-created Secrets Manager
      secret (`{"username": …, "password": …}`) referenced by ARN through
      `repositoryCredentials` in the container definition, with the execution
      role granted `secretsmanager:GetSecretValue` on that one ARN. Unlike the
      Azure case above, only the secret's **ARN** travels through the platform
      — the credential itself never leaves Secrets Manager, so the custody
      problem in `tempdocs/cr-secret-keyvault.md` does not arise
