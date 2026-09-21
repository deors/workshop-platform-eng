#!/usr/bin/env bash
#
# setup-azure-fedcreds.sh — configure the platform's GitHub OIDC federated
# credentials on the Azure app registration used by the workflows.
#
# Usage:
#   ./setup-azure-fedcreds.sh [<tenant-id>] [<client-id>]
#
# Both identifiers resolve the same way, in this order — the first non-empty
# value wins (the same precedence the workflows use):
#   tenant  : argument 1 → AZURE_TENANT_ID  → PROVISION_AZURE_TENANT_ID (repo variable)
#   client  : argument 2 → AZURE_CLIENT_ID  → PROVISION_AZURE_CLIENT_ID (repo variable)
# The script refuses to run unless the Azure CLI is currently logged into
# exactly the resolved tenant — a guard against operating on the wrong
# directory.
#
# Optional environment:
#   PLATFORM_REPO    <owner>/<name> of the platform repo whose workflows log
#                    in with the app (default: the checkout this script lives
#                    in — scripts/local/ of the platform repo — via `gh repo view`)
#   SUBJECT_PREFIX   OIDC subject prefix the repo presents (default: queried
#                    from GitHub — `repo:<owner>/<name>`, or the immutable-ID
#                    form `repo:<owner>@<id>/<name>@<id>` for repos created
#                    after 2026-07-15). Never guessed: a wrong prefix fails
#                    later at login with AADSTS700213.
#   ENVIRONMENTS     space-separated environments (default: "dev staging prod")
#
# Converges the app registration on exactly these federated credentials,
# named as in docs/setup-azure.md, issuer https://token.actions.githubusercontent.com,
# audience api://AzureADTokenExchange:
#   github-main-branch   <prefix>:ref:refs/heads/main
#   github-env-<env>     <prefix>:environment:<env>   (one per environment)
# Per credential it reports created / already OK / updated. A credential
# with one of those names but a different subject, issuer or audience is
# only rewritten after an explicit typed confirmation. Credentials with
# other names (app repos registered by the provisioning workflow, other
# platforms sharing the identity) are listed and never touched.
#
# Requires: `az` logged in with permission to edit the app registration
# (owner of the app, or Application.ReadWrite.All), `gh` authenticated (repo
# admin, to read the OIDC subject prefix), and `jq`.

set -euo pipefail

ISSUER="https://token.actions.githubusercontent.com"
AUDIENCE="api://AzureADTokenExchange"
ENVIRONMENTS="${ENVIRONMENTS:-dev staging prod}"
GUID='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

log() { echo "[setup-azure-fedcreds] $*" >&2; }
err() { echo "[setup-azure-fedcreds] ERROR: $*" >&2; exit 1; }
ok()  { echo "[setup-azure-fedcreds] ✓ $*" >&2; }

for BIN in az gh jq; do command -v "${BIN}" >/dev/null || err "'${BIN}' is required"; done

# This script lives in scripts/local/ of the platform repo checkout.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PLATFORM_REPO="${PLATFORM_REPO:-$(cd "${REPO_ROOT}" && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)}"
[ -n "${PLATFORM_REPO}" ] || err "could not determine the platform repo; set PLATFORM_REPO=<owner>/<name>"

# Prints the repo variable's value, or nothing when unset.
repo_var() { gh variable get "$1" -R "${PLATFORM_REPO}" 2>/dev/null || true; }

# ── Identifiers: argument → environment → repo variable ─────────────────────

TENANT_ID="${1:-${AZURE_TENANT_ID:-$(repo_var PROVISION_AZURE_TENANT_ID)}}"
[ -n "${TENANT_ID}" ] || err "no tenant ID: pass it as argument 1, set AZURE_TENANT_ID, or set the PROVISION_AZURE_TENANT_ID repo variable"
[[ "${TENANT_ID}" =~ ${GUID} ]] || err "'${TENANT_ID}' is not a tenant ID (GUID)"

CLIENT_ID="${2:-${AZURE_CLIENT_ID:-$(repo_var PROVISION_AZURE_CLIENT_ID)}}"
[ -n "${CLIENT_ID}" ] || err "no client ID: pass it as argument 2, set AZURE_CLIENT_ID, or set the PROVISION_AZURE_CLIENT_ID repo variable"
[[ "${CLIENT_ID}" =~ ${GUID} ]] || err "'${CLIENT_ID}' is not a client ID (GUID)"

# ── Guards ───────────────────────────────────────────────────────────────────

if ! CURRENT_TENANT=$(az account show --query tenantId -o tsv 2>/dev/null); then
  err "the Azure CLI is not logged in (az account show failed)"
fi
if [ "$(tr "[:upper:]" "[:lower:]" <<<"${CURRENT_TENANT}")" != "$(tr "[:upper:]" "[:lower:]" <<<"${TENANT_ID}")" ]; then
  err "the Azure CLI is logged into tenant ${CURRENT_TENANT}, not ${TENANT_ID}; run 'az login --tenant ${TENANT_ID}' first"
fi

# The subject prefix must come from GitHub, never be assumed.
if [ -z "${SUBJECT_PREFIX:-}" ]; then
  SUBJECT_PREFIX="$(gh api "repos/${PLATFORM_REPO}/actions/oidc/customization/sub" --jq '.sub_claim_prefix // empty' 2>/dev/null || true)"
  [ -n "${SUBJECT_PREFIX}" ] || err "could not read the OIDC subject prefix of ${PLATFORM_REPO} (GET repos/${PLATFORM_REPO}/actions/oidc/customization/sub); set SUBJECT_PREFIX explicitly"
fi

APP_OBJECT_ID="$(az ad app list --app-id "${CLIENT_ID}" --query '[0].id' -o tsv 2>/dev/null || true)"
[ -n "${APP_OBJECT_ID}" ] || err "no app registration with client ID ${CLIENT_ID} in tenant ${TENANT_ID}"

log "tenant        ${TENANT_ID}"
log "app (client)  ${CLIENT_ID}"
log "platform repo ${PLATFORM_REPO}"
log "subject prefix ${SUBJECT_PREFIX}"

# ── Desired credentials ──────────────────────────────────────────────────────

declare -a NAMES SUBJECTS
NAMES=(github-main-branch); SUBJECTS=("${SUBJECT_PREFIX}:ref:refs/heads/main")
for ENV in ${ENVIRONMENTS}; do
  NAMES+=("github-env-${ENV}"); SUBJECTS+=("${SUBJECT_PREFIX}:environment:${ENV}")
done

EXISTING="$(az ad app federated-credential list --id "${APP_OBJECT_ID}" -o json)"
COUNT="$(jq 'length' <<<"${EXISTING}")"
MISSING=0
for i in "${!NAMES[@]}"; do
  jq -e --arg n "${NAMES[$i]}" 'map(select(.name == $n)) | length == 0' <<<"${EXISTING}" >/dev/null && MISSING=$((MISSING + 1))
done
# Entra allows at most 20 federated credentials per app registration.
if [ $((COUNT + MISSING)) -gt 20 ]; then
  err "the app already has ${COUNT} federated credentials; adding ${MISSING} more exceeds the limit of 20"
fi

desired_json() {
  jq -nc --arg n "$1" --arg s "$2" --arg i "${ISSUER}" --arg a "${AUDIENCE}" \
    '{name: $n, issuer: $i, subject: $s, audiences: [$a], description: "workshop-platform-eng GitHub Actions OIDC"}'
}

for i in "${!NAMES[@]}"; do
  NAME="${NAMES[$i]}"; SUBJECT="${SUBJECTS[$i]}"
  CURRENT="$(jq -c --arg n "${NAME}" 'map(select(.name == $n)) | .[0] // empty' <<<"${EXISTING}")"
  if [ -z "${CURRENT}" ]; then
    az ad app federated-credential create --id "${APP_OBJECT_ID}" --parameters "$(desired_json "${NAME}" "${SUBJECT}")" -o none
    ok "created  ${NAME}  →  ${SUBJECT}"
    continue
  fi
  if jq -e --arg s "${SUBJECT}" --arg i "${ISSUER}" --arg a "${AUDIENCE}" \
       '.subject == $s and .issuer == $i and (.audiences == [$a])' <<<"${CURRENT}" >/dev/null; then
    ok "already OK  ${NAME}  →  ${SUBJECT}"
    continue
  fi
  log "'${NAME}' exists with a different definition:"
  log "  current: $(jq -r '"\(.subject)  issuer=\(.issuer)  audiences=\(.audiences|join(","))"' <<<"${CURRENT}")"
  log "  desired: ${SUBJECT}  issuer=${ISSUER}  audiences=${AUDIENCE}"
  printf "Type 'UPDATE %s' to rewrite it, anything else to keep it: " "${NAME}" >&2
  read -r ANSWER </dev/tty
  if [ "${ANSWER}" = "UPDATE ${NAME}" ]; then
    CRED_ID="$(jq -r .id <<<"${CURRENT}")"
    az ad app federated-credential update --id "${APP_OBJECT_ID}" --federated-credential-id "${CRED_ID}" \
      --parameters "$(desired_json "${NAME}" "${SUBJECT}")" -o none
    ok "updated  ${NAME}  →  ${SUBJECT}"
  else
    log "kept ${NAME} unchanged"
  fi
done

OTHERS="$(jq -r --argjson names "$(printf '%s\n' "${NAMES[@]}" | jq -R . | jq -sc .)" \
  'map(select(.name as $n | $names | index($n) | not)) | .[] | "  \(.name)  →  \(.subject)"' <<<"${EXISTING}")"
if [ -n "${OTHERS}" ]; then
  log "other federated credentials on this app (left untouched):"
  printf '%s\n' "${OTHERS}" >&2
fi

echo
echo "Done. The platform workflows can log in again."
if [ -z "$(repo_var PROVISION_AZURE_CLIENT_ID)" ]; then
  echo "PROVISION_AZURE_CLIENT_ID is not set on ${PLATFORM_REPO}; to make it the organization default:"
  echo "  gh variable set PROVISION_AZURE_CLIENT_ID -R ${PLATFORM_REPO} --body \"${CLIENT_ID}\""
fi
