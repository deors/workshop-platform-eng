---
title: Setup Guide for AWS
---

[← back to home](index.md)

Wires this platform to an **AWS account**: the identity it authenticates with,
the permissions it needs, and the S3 bucket that holds Terraform state. When
you finish, the platform is ready for its first
`AWS - Provision & Reconcile Application Resources` run.

> **Do the [GitHub setup](setup-github.md) first.** This guide assumes the
> repository is already on GitHub and its `dev` / `staging` / `prod`
> Environments exist — the OIDC trust subjects below are scoped to that
> repository slug and those environment names.

It assumes you have **administrator** rights on the target AWS account
(creating the OIDC identity provider and IAM roles requires IAM write access).

## What you'll end up with

- A **GitHub OIDC identity provider** registered in IAM — **no access keys
  stored anywhere**.
- One **IAM role** whose trust policy accepts four OIDC subjects, covering
  the bootstrap workflow and the three per-environment plan/apply/verify jobs.
- The role granted the permissions needed to bootstrap state storage,
  provision infrastructure, and **edit its own trust policy** (the AWS
  analogue of Azure's self-managed federated credentials).

Estimated time: **10–15 minutes** the first time.

---

## Prerequisites

Tooling on your workstation, on top of what the GitHub guide lists:

| Tool | Minimum version | Notes |
|------|-----------------|-------|
| `aws` | 2.15 (CLI v2) | OIDC provider + IAM role + policies |
| `jq` (optional) | 1.6 | Useful for inspecting `aws` output |

AWS access:

- An existing AWS account where you can create IAM identity providers, roles
  and policies.
- A **Route 53 public hosted zone** for the domain you'll pass as
  `main_domain`, in the **same account**. This is required — the AWS workflow
  treats `main_domain` as mandatory: the template derives each environment's
  FQDN as `<app_name>.<environment>.<main_domain>`, looks the zone up by
  name, and issues a DNS-validated ACM certificate against it. Without the
  zone, `terraform apply` fails with `no matching Route53Zone found`.

There is nothing to pre-create for networking or compute: the template builds
its own VPCs, subnets and NAT gateways per environment.

---

## Step 1 — Register the GitHub OIDC identity provider

The workflows authenticate to AWS with short-lived OIDC tokens issued by
GitHub Actions. IAM validates each token against an **identity provider**
registered once per account:

```bash
# Make sure you're operating against the intended account
aws sts get-caller-identity

aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1

# Capture the account ID — used in the ARNs below
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export OIDC_PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
echo $OIDC_PROVIDER_ARN
```

> **Notes.** There can only be one provider per issuer URL per account — if
> the command fails with `EntityAlreadyExists`, the provider is already
> registered (common in shared accounts) and you can simply reuse it. The
> `--thumbprint-list` value is required by the API but effectively
> informational for this issuer: AWS validates GitHub's OIDC endpoint against
> its library of trusted root CAs rather than the pinned thumbprint.

---

## Step 2 — Create the IAM role and its trust policy

The token's `subject` claim must match a subject listed in the role's trust
policy. You need **four** subjects because two different formats apply:

| Subject | Used by |
|---------|---------|
| `repo:<org>/<repo>:ref:refs/heads/main` | every job in `provision-infrastructure-aws.yml` **without** an `environment:` key — `resolve-inputs`, `fmt`, `checkov`, `bootstrap-tfstate`, `create-app-repo`, `create-run-issue`, `configure-environments`, `configure-oidc-trust`, `observe-ci`, `final-summary`; and the standalone `bootstrap-tfstate-aws.yml`, `detect-drift-aws.yml`, `tag-app-resources-aws.yml` and delete workflows |
| `repo:<org>/<repo>:environment:dev` | every job pinned to `environment: dev` — `plan`, `apply`, the `verify-infrastructure-aws.yml` reusable workflow |
| `repo:<org>/<repo>:environment:staging` | same set of jobs, pinned to `environment: staging` |
| `repo:<org>/<repo>:environment:prod` | same set of jobs, pinned to `environment: prod` |

> **Check your repo's subject format first.** GitHub embeds immutable IDs in
> the subject claim of any repository created (or renamed/transferred) after
> July 15, 2026: the prefix becomes `repo:<org>@<owner-id>/<repo>@<repo-id>`
> instead of `repo:<org>/<repo>`, and `StringEquals` matches subjects
> verbatim. Query the exact prefix your platform repo presents and use it in
> the four subjects below:
>
> ```bash
> gh api "repos/$REPO/actions/oidc/customization/sub" --jq .sub_claim_prefix
> ```
>
> The snippet below assumes the legacy prefix, which is what a platform repo
> created before that date presents. The *app* repos the platform creates
> need no such care from you — the `configure-oidc-trust` job queries each
> new repo's actual prefix before appending its subjects.

Unlike Azure — where each federated credential is its own object — all four
subjects live in **one trust-policy document** on the role:

```bash
REPO="<your-org>/<repo-name>"   # e.g. deors/workshop-platform-eng

cat > /tmp/trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Federated": "${OIDC_PROVIDER_ARN}" },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
          "token.actions.githubusercontent.com:sub": [
            "repo:${REPO}:ref:refs/heads/main",
            "repo:${REPO}:environment:dev",
            "repo:${REPO}:environment:staging",
            "repo:${REPO}:environment:prod"
          ]
        }
      }
    }
  ]
}
EOF

aws iam create-role \
  --role-name GitHubActionsPlatformEng \
  --description "OIDC role assumed by the platform-eng GitHub Actions workflows" \
  --assume-role-policy-document file:///tmp/trust-policy.json

export AWS_ROLE_ARN=$(aws iam get-role --role-name GitHubActionsPlatformEng --query Role.Arn --output text)
echo $AWS_ROLE_ARN
```

> **Keep the GitHub subjects in this one statement.** After the platform
> provisions a new app, the `configure-oidc-trust` job **appends** the app
> repo's per-environment subjects (`repo:<owner>/<app>:environment:{dev,staging,prod}`,
> or the immutable-ID variant for repos GitHub creates after July 15, 2026 —
> the job registers whichever prefix the new repo actually presents)
> to the existing GitHub-OIDC statement — it deliberately refuses to create a
> trust statement from scratch, so the run fails with a clear error if none
> exists. The decommission workflow later removes exactly those subjects, in
> either format.
> If your organisation prefers wildcard trust (`StringLike` with
> `repo:<your-org>/*`), that works for pre-cutover repos — the workflow
> detects that a subject is already covered by a wildcard and skips the
> write. Note that such a wildcard does **not** match immutable-ID subjects
> (`repo:<your-org>@<owner-id>/…`), so for app repos created after the
> cutover the job appends their exact subjects as usual; a wildcard covering
> the new format would be `repo:<your-org>@<owner-id>/*`.

---

## Step 3 — Grant IAM permissions

For the workshop baseline, attach the `AdministratorAccess` managed policy —
the moral equivalent of the `Contributor` + `User Access Administrator` pair
the Azure guide assigns at subscription scope:

```bash
aws iam attach-role-policy \
  --role-name GitHubActionsPlatformEng \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess

# Verify
aws iam list-attached-role-policies \
  --role-name GitHubActionsPlatformEng \
  --query "AttachedPolicies[].PolicyName" \
  --output table
```

> **Why so broad?** One run touches S3 (state bucket bootstrap), EC2 (VPC,
> subnets, NAT, security groups, flow logs), ELBv2, ACM, Route 53, ECS,
> Application Auto Scaling, CodeDeploy, CloudWatch (logs, alarms), X-Ray,
> Resource Groups + the Tagging API, **and IAM** — the template creates the
> per-app task and task-execution roles, and the platform edits this role's
> own trust policy. `PowerUserAccess` is **not** enough: it excludes exactly
> those IAM writes. Once the platform serves many apps across many accounts,
> this model should be revisited (scoped policies, permission boundaries, or
> one role per app) — the same caveat the Azure guide makes about its
> subscription-scoped roles.

### Allow the role to manage its own trust policy

This is the AWS analogue of the Azure guide's "manage its own federated
credentials" section, and the easy-to-miss requirement if you scope
permissions down. After provisioning a new app, the platform registers the
app repo's OIDC subjects **on this same role** (job `configure-oidc-trust`);
without it, deploy workflows in the new repo fail at
`aws-actions/configure-aws-credentials` with
`Not authorized to perform sts:AssumeRoleWithWebIdentity`.

`AdministratorAccess` already covers it. If you replace it with scoped
policies, keep this minimum on the role:

```bash
aws iam put-role-policy \
  --role-name GitHubActionsPlatformEng \
  --policy-name self-manage-trust-policy \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": ["iam:GetRole", "iam:UpdateAssumeRolePolicy"],
      "Resource": "arn:aws:iam::'"${ACCOUNT_ID}"':role/GitHubActionsPlatformEng"
    }]
  }'
```

> **Concurrency caveat.** The trust policy is a single document shared by
> every app using this role, and updating it is a read-modify-write. The
> workflows serialise their own edits (`max-parallel: 1`), but provisioning
> or retiring two **different** apps at the same time can still race — the
> last write wins. Run those one at a time.

### State bucket — security model

The state bucket is created by the first run (idempotently, by
`scripts/bootstrap-tfstate-aws.sh`) as `tf-state-<app>-<account8>` with:

- **Versioning enabled** — every state write is recoverable.
- **AES-256 server-side encryption** with bucket keys.
- **All public access blocked** (ACLs and policies).
- A **bucket policy denying non-TLS transport and TLS below 1.3** — the same
  floor as the ALB listener policy, and stricter than the Azure storage
  account, which stays at TLS 1.2 only because Azure Storage does not support
  a 1.3 floor yet.
- Bucket tags **merged, not replaced**, on re-runs — tags applied later by the
  compliance-tagging workflow survive.

There is no DynamoDB lock table: runs for the same app are serialised by the
workflow's concurrency group (`provision-aws-<app_name>`) instead. If you run
Terraform against the bucket locally, avoid doing so while a workflow run is
in flight.

### ALB network exposure — per-environment policy

Application load balancers follow a deliberate per-env split, mirroring the
Azure archetype's Private-Endpoint posture:

| Env | ALB | App DNS record | Rationale |
|-----|-----|----------------|-----------|
| `dev` | **internet-facing** | public hosted zone | GitHub-hosted runners are not in the VPC. Dev intentionally accepts public traffic so the app repo's CI/CD can run a real HTTPS smoke test against `https://<app>.dev.<main_domain>` after each deploy. |
| `staging` | **internal** (private subnets) | VPC-private hosted zone | Mirrors the production posture; the FQDN resolves only inside the VPC. |
| `prod` | **internal**, deletion protection on | VPC-private hosted zone | Internal-only, multi-AZ, autoscaled 3–10 tasks. |

The split-horizon DNS is deliberate: publishing an internal ALB's RFC1918
addresses in public DNS would leak topology and be dropped by resolvers with
DNS-rebinding protection, so staging/prod publish their FQDN at the apex of a
VPC-private zone. Only the ACM validation CNAMEs stay public in every
environment. Deploys to staging/prod therefore validate via **control-plane
assertions only** (service state, deployed task definition) — the same
strategy as Azure's PE-only environments — while dev finishes with a real
HTTPS probe. Deployments use rolling updates in dev and **CodeDeploy
blue/green** in staging (linear 10%) and prod (linear 50%, auto-rollback).
Full details in the
[template's README](https://github.com/deors/template-terraform-aws-fargate#environment-specific-baselines).

---

## Step 4 — Trigger the first run

In the GitHub UI: **Actions → AWS - Provision & Reconcile Application
Resources → Run workflow**, and provide:

| Input | Required | Value for the first test |
| ----- | -------- | ------------------------ |
| `app_name` | yes | `test-webapp` (3–22 chars, lowercase, digits, hyphens) |
| `environment` | yes | `dev` |
| `aws_region` | yes | `eu-west-1` — region for the tfstate bucket and every provisioned resource. No default, by design: an implicit region silently deploys to the wrong place |
| `aws_role_arn` | yes | the role ARN captured in step 2 |
| `main_domain` | yes | the root domain of your Route 53 public hosted zone (e.g. `example.com`) — drives the ACM certificate and DNS records for `<app>.<env>.<domain>` |
| `infra_template_repo` | yes | the `<owner>/<name>` of the infrastructure template repo |
| `infra_template_ref` | no | _(leave empty — uses the template's default branch)_ git ref (tag, branch, or commit SHA) to pin the infra template |
| `app_template_repo` | no | the `<owner>/<name>` of the application template repo; **leave empty to skip the app-repo phase** (infra-only run) |
| `app_template_ref` | no | _(leave empty — uses the template's default branch)_ git ref (tag, branch, or commit SHA) to pin the app template |
| `container_image` | no | `public.ecr.aws/nginx/nginx:stable-alpine` |
| `container_port` | no | _(leave empty — defaults to `80`, matching the nginx placeholder; a real app passes its own port, e.g. `8080`)_ |
| `health_check_path` | no | _(leave empty — defaults to `/`, matching the nginx placeholder; a real app passes e.g. `/health`)_ |
| `ci_workflow_file` | no | _(leave empty — defaults to `ci.yml`; only used when `app_template_repo` is set)_ |

> **Reconcile caveat.** `container_image` only matters on the first apply —
> afterwards the ECS service's `lifecycle.ignore_changes` keeps whatever
> CodeDeploy deployed. `container_port` and `health_check_path` are
> different: they drive the ALB target group, which no deployment tool owns,
> so a real application must pass its own values on **every** run — a
> reconcile with the defaults would point the health check back at the
> placeholder's port and path.

### What you should observe

Each row below names the job exactly as it appears in the run's UI. Jobs
marked _(app phase)_ only appear when `app_template_repo` is provided.

```
Resolve inputs                    ✓ validated inputs, derived tf-state-<app>-<acct8> from the role ARN
Checkov · {env}                   ✓ no findings
Terraform fmt check               ✓ formatting clean
Bootstrap tfstate bucket          ✓ S3 bucket + rg-test-webapp-tfstate resource group
Plan · {env}                      ✓ terraform plan generated, artifact uploaded
Apply · {env}                     ✓ terraform apply succeeded (blocks until the ACM cert is ISSUED)
Verify · {env}                    ✓ control-plane assertions passed
Create application repo           ✓ <owner>/<app_name> created from template    (app phase)
Create run issue                  ✓ per-run tracking issue opened               (app phase)
Configure env · {env}             ✓ GitHub Environment + variables set          (app phase)
OIDC trust · {env}                ✓ subject appended to the role trust policy   (app phase)
Observe CI in app repo            ✓ CI watched, build+test+dev-deploy succeeded (app phase, first run only)
Comment on app issue              ✓ summary posted as issue comment             (app phase)
Comment on infra issue            ✓ plan + verify results posted to infra issue
Final summary                     ✓ consolidated summary with links to issues
```

The exact bucket name shows up in the `bootstrap-tfstate` job logs as
`TFSTATE_BUCKET=...`. The plan output (and the binary `tfplan` file) is
attached as a workflow artifact named `tfplan-aws-test-webapp-dev`, retained
for 7 days. The plan is then consumed by the `apply` job, which provisions
the resources for real, after which `verify` runs control-plane assertions
against the live infrastructure.

When `app_template_repo` is provided, the run also creates the application
repository from your template, configures its GitHub Environments + variables
(`AWS_REGION`, `AWS_ROLE_ARN`, `AWS_ECS_CLUSTER`, `AWS_ECS_SERVICE`,
`AWS_APP_URL`, and `DEPLOY_TARGET_CLOUD=aws` — the environment-scoped switch
the app repo's deploy router reads to pick its cloud, so different
environments of one app can target different clouds), appends the per-env
OIDC subjects to the role's trust policy,
observes the auto-triggered CI in the new repo, and posts a summary comment on
the per-run tracking issue. When `app_template_repo` is omitted, all of those
steps are skipped and only the infra issue and final summary are written.

---

## Step 5 — Configure scheduled drift detection (optional)

The `detect-drift-aws.yml` workflow compares the recorded Terraform state
against the live AWS resources (`terraform plan -refresh-only`) and opens an
issue in the affected application's **infrastructure repo** (`<app>-infra`)
when it finds drift or an error. It has three entry points: a weekly
`schedule` (Mondays at 06:23 UTC — one hour after the Azure sweep, so the two
never contend for runners), manual `workflow_dispatch`, and `workflow_call`.

For each environment the workflow classifies the result from the
(managed-state × live-resources) matrix. Because an AWS resource group is
only a saved tag query — it can exist while matching nothing — the "live"
side counts the resources actually carrying the environment's tags
(`application=<app>`, `environment=<env>`) via the Resource Groups Tagging
API rather than testing group existence:

| Terraform state | Tagged resources | Result |
|-----------------|------------------|--------|
| empty / missing | none | ⏭️ **skipped** — never provisioned |
| empty / missing | some | 🔴 **drift** — unmanaged/orphaned resources |
| has resources | none | 🔴 **drift** — all managed resources missing |
| has resources | some | refresh-only plan → ✅ no drift, 🔴 drift, or ⚠️ error |

When drift is found the run stays **green** and reports via an issue; the run
only goes **red** when the check itself errors, exactly as on Azure. The raw
plan output, binary plan and plan JSON are uploaded as the `drift-aws-<app>`
artifact.

The **scheduled run** reads its parameters from repository variables, all
`DRIFT_AWS_`-prefixed:

| Repository variable | Required | Description |
|---------------------|----------|-------------|
| `DRIFT_AWS_APP_NAMES` | yes | Application name(s) to check, comma-separated (e.g. `myapp,otherapp`). One matrix job per app. |
| `DRIFT_AWS_ENVIRONMENTS` | no | Environment(s) to check: `all` (default) or a comma-separated subset of `dev`/`staging`/`prod`. |
| `DRIFT_AWS_REGION` | yes | AWS region holding the apps' resources and tfstate bucket. |
| `DRIFT_AWS_ROLE_ARN` | yes | ARN of the IAM role from step 2. |
| `DRIFT_AWS_MAIN_DOMAIN` | yes | Root domain the apps were provisioned with. Required: the template gates its ACM/Route 53 resources on `main_domain != ""`, so an empty value would silently under-report drift on them, and a wrong one fails the plan loudly — preferable to a quiet gap. |

Set them under **Settings → Secrets and variables → Actions → Variables**, or
via the CLI:

```bash
gh variable set DRIFT_AWS_APP_NAMES    -R <org>/<platform-repo> --body "test-webapp"
gh variable set DRIFT_AWS_ENVIRONMENTS -R <org>/<platform-repo> --body "all"
gh variable set DRIFT_AWS_REGION       -R <org>/<platform-repo> --body "eu-west-1"
gh variable set DRIFT_AWS_ROLE_ARN     -R <org>/<platform-repo> --body "arn:aws:iam::<account-id>:role/GitHubActionsPlatformEng"
gh variable set DRIFT_AWS_MAIN_DOMAIN  -R <org>/<platform-repo> --body "example.com"
```

The drift job authenticates with the **branch-scoped** trust subject
(`repo:<org>/<repo>:ref:refs/heads/main`) already configured in step 2 — it
is read-only and never binds a GitHub Environment, so no extra OIDC subject
is needed. Issue creation in the `<app>-infra` repo uses the same `GH_PAT`
secret configured in the [GitHub setup guide](setup-github.md).

The `DRIFT_AWS_*` variables are the opt-in for the scheduled sweep — the
schedule itself ships with the workflow file. If **none** of them are set,
a scheduled run skips cleanly with a notice in its summary. If only **some**
are set (or any other required input is missing), the run fails fast with a
clear error: partial configuration is a mistake, and silence would hide it.

---

## Troubleshooting

AWS identity/login failures (`Not authorized to perform
sts:AssumeRoleWithWebIdentity`, `Could not load credentials`) and Terraform
state problems are collected in [Troubleshooting](troubleshooting.md):

- [Cloud integration and login](troubleshooting.md#cloud-integration-and-login)
- [Terraform state](troubleshooting.md#terraform-state)

For the AWS resources themselves — ECS stabilisation, Route 53 zone lookups,
the template's Checkov baselines, NAT gateway cost — see the
[infrastructure template's troubleshooting](https://github.com/deors/template-terraform-aws-fargate#troubleshooting).

---

## What's next

With the first run green end-to-end, the typical follow-up workshop topics are:

- **Iterate on the application** — push to the new repo's `main`; the
  template's **CI workflow** builds, tests, and (on success) deploys to dev,
  finishing with a real HTTPS smoke test against the public dev FQDN.
- **Promote to staging / prod** — the template ships a **release workflow**
  that promotes a built image to staging and then to prod, using the same
  per-env GitHub Environments + variables this platform configured (so
  `prod` honours whatever protection rules / reviewers you've added on its
  environment). Trigger it by creating a GitHub Release in the app repo —
  `vX.Y.Z-RC` deploys to staging, `vX.Y.Z` deploys to prod. Staging and prod
  deploys go through **CodeDeploy blue/green** and validate via control-plane
  assertions only — HTTP smoke tests don't work from a GitHub-hosted runner
  against internal ALBs (see *ALB network exposure* in step 3).
- **Try the self-service web UI** — enable GitHub Pages on this repo
  (`Settings → Pages → Source: Deploy from a branch / main / /docs`), then
  fire subsequent runs from the [AWS form](provision-aws.html) at
  `https://<owner>.github.io/<repo>/`. The page works for *provision* (new
  env on an existing app) and *reconcile* runs too, not just first-time
  bootstrap — remember the reconcile caveat on `container_port` /
  `health_check_path` above.
- **Pick the next item from the roadmap** — cost reporting, budget alerts,
  and private-registry support via Secrets Manager `repositoryCredentials`
  are the most-requested next steps on the AWS side.
