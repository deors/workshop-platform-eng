# Self-service web page on GitHub Pages

This `docs/` directory contains a single-file static page
([`index.html`](./index.html)) that lets operators fire the *Provision
Infrastructure* workflow without leaving the browser. The page:

- Explains what the platform does, what resources are provisioned, and what
  configuration is applied per environment.
- Renders a form with one field per workflow input (with validation patterns:
  GUIDs, `app_name` regex, `owner/name` for repos).
- Builds and previews the equivalent `curl` command as the form is filled.
- On submit, calls `POST /repos/<owner>/<name>/dispatches` against the
  GitHub API using `fetch`, with a token entered by the user.

The token is **never persisted** — it lives in the page's memory for the
lifetime of the tab.

## Enabling Pages on this repo

1. Push these files to `main` (or your default branch).
2. Repo **Settings → Pages → Build and deployment**:
   - **Source:** *Deploy from a branch*
   - **Branch:** `main`
   - **Folder:** `/docs`
   - Click **Save**.
3. Wait a minute, then visit
   `https://<owner>.github.io/<repo>/` — the form should load.

The empty `.nojekyll` file alongside `index.html` disables Jekyll
processing, so the HTML is served verbatim and `SETUP.md` / `PAGES.md`
remain plain markdown.

## Token requirements

The operator submitting the form needs a token with permission to call the
`POST /repos/<owner>/<repo>/dispatches` endpoint:

- **Fine-grained PAT or GitHub App installation token:** *Repository
  permissions → Contents → Read and write* on this repository.
- **Classic PAT:** `repo` scope.

That's the only scope needed — the token itself does **not** require any
Azure or template-repo permissions. Once dispatched, the workflow uses the
platform's `GH_PAT` (for cross-repo operations) and OIDC federated
credentials (for Azure) to do everything else.

> **Gotcha:** "Actions: write" sounds like the right permission for
> triggering workflows but it isn't enough for `repository_dispatch` —
> GitHub specifically requires Contents:write here. If you see
> `HTTP 403: Resource not accessible by personal access token`, this is
> almost always the cause.

## Auto-detected repo

The page reads `window.location` to pre-fill the *Platform repo* field as
`<owner>/<repo>` when served from `<owner>.github.io/<repo>/`. The field is
still editable, in case the page is served from somewhere else (a fork,
local file, etc.).
