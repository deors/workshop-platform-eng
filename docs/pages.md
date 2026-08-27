---
title: Pages site
---

[← back to home](.)

# Pages site — structure and setup

This `docs/` directory is published as a **GitHub Pages** site rendered by
Jekyll. It serves as the platform's public documentation hub and hosts the
self-service provisioning forms.

## Site map

Pages split into three groups: cloud-agnostic entry points, one page per
cloud, and project meta. Cloud-specific pages carry a `-<cloud>` suffix so a
new cloud is added by dropping in new files, never by editing the shared ones.

| URL (relative to the Pages root) | Source | Purpose |
|----------------------------------|--------|---------|
| `/` | `index.md` | Homepage — what the platform does, architecture, conventions, roadmap. |
| `/provision.html` | `provision.html` | Provisioning entry point: explains the generic run, links to the per-cloud forms. |
| `/provision-azure.html` | `provision-azure.html` | Self-service provisioning form for Azure App Service. |
| `/setup-github/` | `setup-github.md` | One-time GitHub setup — identical for every cloud. Do this first. |
| `/setup-azure/` | `setup-azure.md` | One-time Azure setup — identity, RBAC, state backend. |
| `/CONTRIBUTING/` | `CONTRIBUTING.md` | Contribution guidelines (mirror of the repo-root file). |
| `/pages/` | `pages.md` | This page. Acts as a site map. |

The Jekyll site uses `jekyll-theme-cayman` plus the GitHub-Pages-whitelisted
plugins `jekyll-relative-links` (rewrites `*.md` links to their rendered URLs
at build time) and `jekyll-default-layout` (applies the theme's layout to
pages that don't declare one).

## The self-service provisioning forms

[`provision.html`](provision.html) is the cloud-agnostic entry point. It
describes the shape of a provisioning run — describe the app, dispatch the
workflow, Terraform plans and applies, the archetype verifies itself — and
hands off to a per-cloud form.

Each per-cloud form (e.g., [`provision-azure.html`](provision-azure.html))
is a single-file static page that lets operators fire that cloud's
*Provision & Reconcile Application Resources* workflow without leaving the
browser. Every form:

- Explains what gets provisioned and what configuration is applied per
  environment, for that cloud.
- Renders a form with one field per workflow input, with validation patterns
  (identifiers, `app_name` regex, `owner/name` for repos).
- Builds and previews the equivalent `curl` command as the form is filled.
- On submit, calls `POST /repos/<owner>/<name>/dispatches` against the
  GitHub API using `fetch`, with a token entered by the user.

The token is **never persisted** — it lives in the page's memory for the
lifetime of the tab.

## Enabling Pages on this repo

1. Push the contents of `docs/` to `main` (or your default branch).
2. Repo **Settings → Pages → Build and deployment**:
   - **Source:** *Deploy from a branch*
   - **Branch:** `main`
   - **Folder:** `/docs`
   - Click **Save**.
3. Wait a minute, then visit
   `https://<owner>.github.io/<repo>/` — the documentation home should load,
   and `/provision.html` should offer the per-cloud forms.

Jekyll picks up `_config.yml` from the `docs/` folder automatically; no
further configuration is required on the Pages side.

## Token requirements

The operator submitting a provisioning form needs a token with permission to
call the `POST /repos/<owner>/<repo>/dispatches` endpoint:

- **Fine-grained PAT or GitHub App installation token:** *Repository
  permissions → Contents → Read and write* on this repository.
- **Classic PAT:** `repo` scope.

That's the only scope needed — the token itself does **not** require any
cloud or template-repo permissions. Once dispatched, the workflow uses the
platform's `GH_PAT` (for cross-repo operations) and OIDC (for the target
cloud) to do everything else.

> **Gotcha:** "Actions: write" sounds like the right permission for
> triggering workflows but it isn't enough for `repository_dispatch` —
> GitHub specifically requires Contents:write here. If you see
> `HTTP 403: Resource not accessible by personal access token`, this is
> almost always the cause.

## Auto-detected repo

Each provisioning form reads `window.location` to pre-fill the *Platform repo*
field as `<owner>/<repo>` when served from `<owner>.github.io/<repo>/`. The
field is still editable, in case the page is served from somewhere else (a
fork, local file, etc.).

## Adding a new cloud

To publish a cloud that doesn't exist here yet:

1. Add `provision-<cloud>.html` and `setup-<cloud>.md`, mirroring the Azure pair.
2. Add both to the site map above.
3. Replace the placeholder card for that cloud in `provision.html` with a link
   to the new form, and add its row to the setup table on that page.
4. Link the setup guide from the *What's next* section of
   [`setup-github.md`](setup-github.md).

`index.md` should not need editing — it stays cloud-agnostic and points at
`provision.html`.
