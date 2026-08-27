---
title: Setup Guide for GitHub
---

[← back to home](.)

# Setup Guide for GitHub

The platform's setup splits in two halves:

1. **This guide** — the GitHub side, identical whichever cloud you target:
   hosting the repository, creating Environments, and the tokens the workflows
   need to reach other repositories.
2. **A cloud guide** — the identity, permissions and state backend for your
   target cloud. Pick one once you finish here:
   [Azure](setup-azure.md) · *AWS — coming soon*.

Do this guide first. The cloud guides assume the repository exists and its
Environments are in place, because the OIDC trust they configure is scoped to
this repository and to those environment names.

Estimated time: **5–10 minutes**.

## What you'll end up with

- A GitHub repository hosting this platform code.
- Three GitHub Environments (`dev`, `staging`, `prod`), with optional
  approval gates on `prod`.
- A `GH_PAT` secret so the workflows can act on the *application* repository
  they create (only needed for full mode — see step 4).

---

## Prerequisites

Tooling on your workstation:

| Tool | Minimum version | Notes |
|------|-----------------|-------|
| `git` | 2.30 | Push the repo to GitHub |
| `gh` (optional) | 2.40 | Convenient for environment/secret commands |

GitHub access:

- A GitHub account or organization where you'll host the repository.
- The ability to create Environments (free for public repos, and for private
  repos on paid plans).

Your cloud guide lists its own tooling (`az`, `aws`, …) on top of this.

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

> **Note.** Every OIDC trust you configure in a cloud guide — Azure federated
> credentials, an AWS role trust policy — pins tokens to this exact repository
> slug and to the `main` branch. If you push to a different branch or rename
> the repo later, you must update that trust configuration too.

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

## Step 3 — Handle GitHub Advanced Security (optional)

The `checkov` job uploads its findings as SARIF to **Security → Code scanning**.
Code scanning requires GitHub Advanced Security, which is:

- Free for **public** repositories.
- A paid add-on for **private** repositories on personal accounts.

If you can't enable it, the upload step will fail. Either:

1. **Make the repository public** (recommended for this workshop), or
2. Disable the SARIF upload by adding `if: false` to the
   `Upload SARIF to GitHub Security tab` step in the provisioning workflow.
   The Checkov scan itself still runs and still fails the build on findings.

---

## Step 4 — Provide a `GH_PAT` secret for cross-repo operations

> **Infra-only runs:** if you intend to use the platform exclusively for
> infrastructure-only provisioning (no `app_template_repo`), this step is
> **not required** — the app-repo phase is skipped entirely and
> `GH_PAT` is never accessed.

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

Create one at <https://github.com/settings/tokens?type=beta> (fine-grained,
recommended) with the target organization and `Administration: Read and write`,
`Contents: Read and write`, `Issues: Read and write`, `Actions: Read and write`,
`Variables: Read and write`, `Environments: Read and write` repository
permissions. Save it as the `GH_PAT` secret on this platform repo.

> **Why a PAT and not the workflow token?** GitHub deliberately scopes
> `GITHUB_TOKEN` to the repository running the workflow. Cross-repo writes
> require a token whose installation/owner has access to the target.

---

## Step 5 — Enable GitHub Pages (optional)

The `docs/` folder doubles as the platform's documentation site and hosts the
self-service provisioning forms. To publish it, see
[Pages site — structure and setup](pages.md).

---

## Troubleshooting

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

### Environments exist but OIDC still fails

Check the environment **name** matches exactly — the OIDC subject is
`repo:<org>/<repo>:environment:<env>`, and `Dev` will not match `dev`. The
cloud guides cover the rest of the trust configuration.

---

## What's next

Continue with the guide for your target cloud:

- **[Setup Guide for Azure](setup-azure.md)** — App Registration, federated
  credentials, RBAC roles, and the Terraform state storage account.
- **AWS** — *coming soon*: OIDC identity provider, IAM role trust policy, and
  the Terraform state S3 bucket.
