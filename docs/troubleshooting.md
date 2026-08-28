---
title: Troubleshooting
description: Self-service provisioning & reconciling application resources, multi-cloud, driven by GitHub Actions + Terraform.
---

[← back to home](index.md)

# Troubleshooting

Where a problem is documented follows who owns it:

| Area | Owner | Covered in |
|------|-------|-----------|
| GitHub, Actions, workflows, the provisioning forms | this repository | [below](#github-actions-and-the-provisioning-forms) |
| Terraform remote state | this repository | [below](#terraform-state) |
| Integration and login with a cloud provider | this repository | [below](#cloud-integration-and-login) |
| A cloud's own services and how a template configures them | the infrastructure template | [Azure](https://github.com/deors/template-terraform-azure-webapp#troubleshooting) · [AWS](https://github.com/deors/template-terraform-aws-fargate#troubleshooting) |

The split is deliberate. The platform provisions *any* archetype, so anything
tied to the resources a specific template creates — health checks, DNS,
certificates, per-cloud Checkov baselines — belongs beside that Terraform, not
here. Everything the platform itself owns lives on this page, once, covering
every cloud rather than being restated in each cloud's setup guide.

---

## GitHub, Actions and the provisioning forms

### `HTTP 403: Resource not accessible by personal access token`

Returned by a provisioning form, `scripts/trigger-provision-<cloud>.sh`, or a
raw `POST /repos/<owner>/<repo>/dispatches`.

The token needs **Contents: read and write** (fine-grained PAT or GitHub App
installation token) or the classic `repo` scope. *Actions: write* sounds like
the right permission for triggering a workflow but is **not** accepted for
`repository_dispatch` — this is the most common cause of the 403.

That is the only scope needed. The token does **not** require any cloud or
template-repo permissions; once dispatched, the workflow uses the platform's
`GH_PAT` for cross-repo work and OIDC for the cloud. See
[Token requirements](pages.md#token-requirements).

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

The `checkov` job gates every provisioning run and is scanned per environment:
`prod` against the template's `.checkov.yaml`, `dev`/`staging` against its
`.checkov.nonprod.yaml`. A finding that appears only on `prod` is usually
intentional — the non-prod config skips a handful of prod-only baselines.

Either fix the finding or, if you've judged it a false positive or
not-applicable, add a justified entry to the template's Checkov config
documenting why the check is skipped. See
[`CONTRIBUTING.md`](CONTRIBUTING.md#terraform) for the rules around skips, and
the template's own troubleshooting for which checks it already skips and why.

Findings are uploaded to the repository's *Security* tab under a per-cloud,
per-environment category (`checkov-terraform-<env>` for Azure,
`checkov-terraform-aws-<env>` for AWS) so results from different clouds never
overwrite each other.

### A scheduled drift run does nothing, or reports less drift than expected

`schedule` events cannot carry inputs, so scheduled runs read their parameters
from repository variables (`DRIFT_AZURE_*`, `DRIFT_AWS_*`). A missing required
variable fails the run fast with an explicit error rather than silently doing
nothing.

Note that the cron expression itself **cannot** be driven by a variable:
GitHub does not evaluate `${{ }}` anywhere in the `on:` block, so a templated
schedule is parsed as a literal, malformed cron and never fires. It has to be
a hard-coded string in the workflow file.

Under-reporting is a different failure. Where a template gates resources on an
input being non-empty — AWS's `main_domain`, which guards the ACM certificate
and Route 53 record — passing an empty value makes the refresh-only plan skip
those resources entirely and report *less* drift than exists. Those inputs are
therefore mandatory even though the underlying Terraform variable has a
default. A wrong value fails loudly, which is the intended trade.

### Environments exist but OIDC still fails

Check the environment **name** matches exactly — the OIDC subject is
`repo:<org>/<repo>:environment:<env>`, and `Dev` will not match `dev`.
See [Cloud integration and login](#cloud-integration-and-login) for the rest
of the trust configuration.

---

## Terraform state

The platform owns the state backend for every cloud: one bucket or storage
account per application, bootstrapped by
`scripts/bootstrap-tfstate-<cloud>.sh` and safe to re-run. Symptoms below are
grouped by cloud only where the error text differs.

### `terraform init` cannot find the backend

**AWS — `NoSuchBucket`.** The bucket is named
`tf-state-<app20>-<account8>`, where `<app20>` is the app name lowercased with
`_` stripped and truncated to 20 characters, and `<account8>` is the first 8
characters of the AWS account ID. The formula is duplicated in three places
that must agree: `scripts/bootstrap-tfstate-aws.sh`, `detect-drift-aws.yml`
(which resolves the account via STS after login) and
`provision-infrastructure-aws.yml` (which derives it from field 5 of the role
ARN, with no STS call). If init can't find the bucket, either the bootstrap
job didn't run, or it ran against a different account than plan/apply did —
that is, the role ARN and the credentials in play disagree.

**Azure — `Error refreshing state`.** Most often a missing
`Storage Blob Data Contributor` assignment on the service principal; see the
next entry. If RBAC is correct, confirm the workflow passes `use_oidc=true`
and `use_azuread_auth=true` in its `-backend-config` flags (it does, by
default).

### `AuthorizationFailed` during `bootstrap-tfstate` (Azure)

The service principal lacks one of the three required RBAC roles, or
propagation hasn't finished. Re-run after a minute. If it persists, re-run the
`az role assignment list` command from *step 3* of the
[Azure setup guide](setup-azure.md) and confirm all three roles are listed at
subscription scope.

### `Failed to query container 'tfstate' on '<account>'` (Azure)

`scripts/bootstrap-tfstate-azure.sh` traps this on the
`az storage container exists` call. Two possible causes:

1. **RBAC**: the SP has `Contributor` (control plane) but not
   `Storage Blob Data Contributor` (data plane). Re-check step 3 of the Azure
   setup guide.
2. **Network rules**: the storage account has `defaultAction = Deny` (created
   by an earlier version of the script, or modified manually). The
   GitHub-hosted runner has no fixed egress IP and is blocked. Fix:

   ```bash
   az storage account update \
     --name <account> --resource-group <rg> --default-action Allow
   ```

   The current bootstrap script keeps `defaultAction = Allow` by design — see
   the security-model note in step 3.

---

## Cloud integration and login

Every cloud uses the same mechanism: GitHub issues a short-lived OIDC token,
the cloud accepts it if the token's **subject** matches something it trusts.
Almost every failure here is a subject that doesn't match, so start by
comparing the exact subject string on both sides.

Three subject shapes are in play. Confusing them explains most "it works for
some jobs but not others" reports:

| Who is authenticating | Subject |
|---|---|
| Platform jobs with no GitHub Environment binding (`resolve-inputs`, `bootstrap-tfstate`, trust registration) | `repo:<owner>/<platform-repo>:ref:refs/heads/main` |
| Platform jobs bound to an environment (`plan`, `apply`, `verify`) | `repo:<owner>/<platform-repo>:environment:<env>` |
| The application repo's own deploy workflow | `repo:<owner>/<app>:environment:<env>` |

The first two are part of the one-time cloud setup. Only the third is
registered automatically, by the provisioning workflow, and only when an
application template repo was supplied — an infra-only run never registers
app-repo subjects.

### Both clouds — the subject has `@<numbers>` in it (repos created after July 15, 2026)

On top of the three shapes there are two subject **formats**. Repositories
created (or renamed/transferred) after July 15, 2026 present immutable-ID
subjects — `repo:<owner>@<owner-id>/<repo>@<repo-id>:…` instead of
`repo:<owner>/<repo>:…` — and both Entra and IAM match subjects verbatim, so
a credential registered in one format never matches a token minted in the
other. The tell is the assertion subject quoted in the error containing
`@<numbers>`, e.g.:

> AADSTS700213: No matching federated identity record found for presented
> assertion subject 'repo:deors@4376867/test-webapp@1349999312:environment:dev'.

The provisioning workflows handle this themselves: they ask GitHub which
prefix the new app repo actually presents
(`gh api repos/<owner>/<repo>/actions/oidc/customization/sub`) before
registering its subjects, and the decommission workflows remove either
format. Where it can still bite you is the **platform repo's own** manually
registered subjects: if you stand up a fresh platform repo after the cutover,
query its prefix with the same API call and register the four setup-guide
subjects with that prefix.

### Azure — `AADSTS70021` / `AADSTS700213`: `No matching federated identity record found`

The token's subject doesn't match any federated credential on the App
Registration. Re-check:

- The repo slug is exactly `<org>/<repo>` — case-sensitive.
- The subject **format** matches: if the quoted assertion subject contains
  `@<numbers>`, see the previous section — the repo presents immutable-ID
  subjects and the credential was registered in the legacy format.
- For environment subjects, the GitHub Environment exists with the exact
  name (`dev`, `staging`, `prod`) and the job runs against it.
- If you triggered the workflow from a branch other than `main`, the
  branch-scoped credential won't match. Either trigger from `main` or add
  another federated credential for that branch.

### Azure — `Insufficient privileges to complete the operation` registering a federated credential

The `configure-federated-credentials` job calls
`az ad app federated-credential create`, which hits Microsoft Graph
(`POST /applications/{id}/federatedIdentityCredentials`). Two things are
required and people commonly stop after the first:

1. The SP is an **owner** of its own App Registration
   (`az ad app owner add …`).
2. The SP has the `Application.ReadWrite.OwnedBy` Graph application
   permission **with admin consent**.

Without (2), even a fully-owning SP gets `Insufficient privileges`. Run the
two-step procedure in *step 3 — Allow the SP to manage its own federated
credentials* of the [Azure setup guide](setup-azure.md). Step (2) requires a
directory-role admin (Global, Privileged Role, Cloud Application, or
Application Administrator) — in a corporate tenant this is usually an internal
request.

### AWS — `Not authorized to perform sts:AssumeRoleWithWebIdentity`

Raised in the **application** repo's deploy workflow, on
`aws-actions/configure-aws-credentials` — not in the platform repo. The IAM
role's trust policy has no subject matching
`repo:<owner>/<app>:environment:<env>`.

Check, in order:

1. Is the subject actually there?

   ```bash
   aws iam get-role --role-name <role> --query 'Role.AssumeRolePolicyDocument'
   ```

2. Does the subject **format** match? A repo created after July 15, 2026
   presents `repo:<owner>@<owner-id>/<app>@<repo-id>:environment:<env>` —
   a legacy-format entry (or a `repo:<owner>/*` wildcard) never matches it.
   See the format section above.
3. Did the `configure-oidc-trust` job run, or was it skipped? Skipped means it
   was an infra-only run.
4. Did it fail with *"has no statement federating
   token.actions.githubusercontent.com"*? Then the one-time AWS setup was
   never completed: the GitHub OIDC identity provider and the role's trust
   statement must exist before the workflow can add subjects to them. The
   workflow deliberately refuses to invent a trust statement — getting that
   wrong is a security problem, not a convenience.

The role also needs `iam:GetRole` and `iam:UpdateAssumeRolePolicy` **on
itself**. Easy to miss, because every other part of the pipeline works without
them.

### AWS — a trust subject registered earlier has disappeared

The assume-role policy is a single document, frequently shared by several
applications, and registering a subject is a read-modify-write. Concurrent
writers lose updates: last write wins.

Handled within one run — `configure-oidc-trust` sets `max-parallel: 1`, so an
app's own `dev`/`staging`/`prod` serialise, and the teardown workflows do the
same. **Not** handled: two *different* applications provisioning or being
retired at the same time against the same role. Provision and retire apps that
share a role one at a time.
