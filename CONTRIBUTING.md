# Contributing

Thanks for your interest in improving this platform. This document explains
how to propose changes, the standards we hold the code to, and what reviewers
will look for.

By participating in this project you agree to abide by basic norms of
respectful, inclusive, professional communication. Be kind, assume good
intent, and give constructive feedback.

## Ways to contribute

- **Report a bug or rough edge.** Open an issue with reproduction steps, the
  workflow run URL (or a redacted log excerpt), and what you expected to
  happen. Don't paste subscription IDs, tenant IDs, or service principal
  identifiers — redact them as `<sub-id>`, `<tenant-id>`, etc.
- **Suggest an improvement.** Open an issue describing the use case before
  writing code, especially for new modules, new variables on existing
  modules, or changes to environment policies (SKUs, autoscale, networking).
  Alignment up-front avoids wasted work.
- **Submit a pull request.** Small, focused PRs get reviewed and merged
  faster. If your change is large, split it.

## Before you start

- Search existing issues and PRs — your idea may already be in flight.
- For non-trivial changes, open an issue first and wait for a 👍 from a
  maintainer before investing time. We may have constraints (security,
  compliance, cost) that aren't obvious from the code.
- Fork the repository and work on a topic branch named after the change,
  e.g. `feat/postgres-module`, `fix/checkov-skip-justification`.

## Development workflow

### Prerequisites

- Terraform `>= 1.9`
- Azure CLI `>= 2.60`
- Checkov (`pip install checkov`)
- Bash 4+ (for the bootstrap script)

### Local validation

Run the same checks CI runs, before you push:

```bash
# Format
terraform fmt -recursive terraform/

# Validate every environment
for env in dev staging prod; do
  (cd terraform/environments/$env && terraform init -backend=false && terraform validate)
done

# Security scan
checkov --directory terraform/ --framework terraform --config-file .checkov.yaml
```

If Checkov reports a finding you believe is a false positive or genuinely not
applicable, **document the rationale in `.checkov.yaml`** alongside the skip
entry. Reviewers will reject blanket skips.

### Testing infrastructure changes

There is no automated end-to-end test harness yet. For changes that touch
the Terraform modules, please:

1. Run `terraform plan` against a real Azure subscription you control.
2. Attach the relevant excerpt of the plan output to the PR description.
3. Note any resource replacements (`-/+`) explicitly — they often hide
   downtime or data loss.

For changes that only touch documentation, scripts, or workflow YAML, no
infrastructure run is required, but explain how you verified the change.

## Coding standards

### Terraform

- One concern per module. Modules expose narrow, well-typed inputs and
  outputs; they don't reach across to siblings.
- Every variable must have a `description` and a `type`. Use `validation`
  blocks for inputs with constrained values (enums, regex).
- Resource names follow `<type>-<app>-<env>` (e.g. `app-myapp-prod`).
- Tag every taggable resource with at least `application`, `environment`,
  `managed-by`, `platform`.
- No hardcoded secrets, no hardcoded subscription IDs, no hardcoded tenant
  IDs anywhere in the Terraform code.
- Prefer `for_each` over `count` for resource collections; use `count` only
  for boolean toggles.
- `lifecycle.ignore_changes` is allowed only with a one-line comment
  explaining why.

### Shell scripts

- `set -euo pipefail` at the top.
- Idempotent by default: every `create` is preceded by an existence check.
- Fail loudly with a clear error message; don't swallow `az` errors.
- All inputs come from named flags (`--app-name`, never positional), and
  required flags are validated up-front.

### GitHub Actions workflows

- Pin third-party actions to a major version tag (`@v4`, `@v12`); avoid
  `@main` or `@master`.
- Set the smallest `permissions:` block that works. Default to read-only at
  the workflow level and grant write per-job when strictly needed.
- Don't print secrets. Use `::add-mask::` for any sensitive value that
  arrives as an input rather than a `secrets.*` reference.
- Prefer OIDC over long-lived credentials.

### Commit messages

We loosely follow Conventional Commits — the `type(scope): subject` form is
helpful but not strictly enforced. Examples:

- `feat(webapp): add support for managed certificate binding`
- `fix(bootstrap): handle pre-existing storage accounts without TLS 1.2`
- `docs(readme): clarify federated credential subjects`

Write the body in the imperative mood and explain *why* the change exists,
not *what* it does — the diff already shows the what.

## Pull request checklist

Before requesting review:

- [ ] `terraform fmt -recursive terraform/` passes
- [ ] `terraform validate` passes in every touched environment
- [ ] Checkov passes (or new skips are documented in `.checkov.yaml`)
- [ ] The PR description states the motivation and lists user-visible changes
- [ ] Any new variable, output, or input is documented in the relevant module
- [ ] No subscription IDs, tenant IDs, or other identifiers are committed

PRs that change defaults or remove variables must call this out clearly under
a `Breaking changes` heading in the description.

## Security

If you believe you've found a security issue, **do not open a public issue**.
Email the maintainers privately at `security@<your-domain>` with reproduction
details, and give us a reasonable window to respond before public disclosure.

## License

By contributing, you agree that your contributions will be licensed under the
project's [MIT license](LICENSE).
