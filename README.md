# Workshop · Platform Engineering

A self-service platform that provisions Azure infrastructure for containerised
web applications, driven by GitHub Actions and Terraform. External systems
trigger the platform through `repository_dispatch` or `workflow_dispatch`
events; the platform takes care of standing up secure, observable,
production-grade environments without the requesting team having to write any
infrastructure code.

> **Status:** functional end-to-end. Plan → apply → verify, application repo
> creation from template, GitHub Environments + variables, OIDC federated
> credentials, CI observation and per-run tracking issue are all wired.

---

## 📖 Documentation lives on the Pages site

The full documentation — overview, architecture, setup guide, conventions,
roadmap, and a self-service provisioning form — is published as a **GitHub
Pages** site rendered from [`docs/`](docs/):

**➜ <https://deors.github.io/workshop-platform-eng/>**

(Replace the URL above with your fork's Pages URL if you've cloned the repo.
The site activates once Pages is enabled on the repository — see
[`docs/PAGES.md`](docs/PAGES.md).)

| What you're looking for | Where |
|-------------------------|-------|
| What the platform provisions, architecture, roadmap | [`docs/index.md`](docs/index.md) (Pages home) |
| One-time setup of App Registration, RBAC, federated credentials, GH_PAT | [`docs/SETUP.md`](docs/SETUP.md) |
| How the Pages site is built and how to enable it | [`docs/PAGES.md`](docs/PAGES.md) |
| Self-service provisioning form (one-click trigger) | [`docs/provision.html`](docs/provision.html) — best viewed on the Pages site |
| Contribution guidelines, coding standards, PR checklist | [`CONTRIBUTING.md`](CONTRIBUTING.md) |

---

## License

[MIT](LICENSE) — see the license file for details.
