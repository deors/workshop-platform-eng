#!/usr/bin/env bash
#
# remove-azure-fedcreds.sh — remove GitHub OIDC federated credentials from
# the Azure app registration used by the platform's workflows.
#
# Usage:
#   ./remove-azure-fedcreds.sh [<tenant-id>] [<client-id>]
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
#   PLATFORM_REPO    <owner>/<name> of the platform repo (default: the checkout
#                    this script lives in — scripts/local/ of the platform repo)
#
# Unlike AWS, where every trusted subject lives inside one trust-policy
# document, Entra keeps one federated-credential object per subject, so
# removal is per object and never affects the others. Nothing else on the
# app registration (secrets, role assignments, owners) is touched.
#
# Safety:
#   - Always lists the exact credentials found, numbered, with their
#     subjects. Nothing is removed without typing an explicit command:
#     'DELETE CREDENTIAL <number>' removes one at a time (the prompt loops so
#     several can be removed), 'DELETE ALL CREDENTIALS' removes every
#     remaining one, and anything else exits.
#   - The confirmation is read from /dev/tty, so it cannot be bypassed by
#     piping input, redirecting stdin, or running non-interactively.
#
# Requires: `az` logged in with permission to edit the app registration
# (owner of the app, or Application.ReadWrite.All), `gh` (only to resolve the
# defaults above), and `jq`.

set -euo pipefail

GUID='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

log() { echo "[remove-azure-fedcreds] $*" >&2; }
err() { echo "[remove-azure-fedcreds] ERROR: $*" >&2; exit 1; }
ok()  { echo "[remove-azure-fedcreds] ✓ $*" >&2; }

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

APP_OBJECT_ID="$(az ad app list --app-id "${CLIENT_ID}" --query '[0].id' -o tsv 2>/dev/null || true)"
[ -n "${APP_OBJECT_ID}" ] || err "no app registration with client ID ${CLIENT_ID} in tenant ${TENANT_ID}"

log "tenant       ${TENANT_ID}"
log "app (client) ${CLIENT_ID}"

# ── List and confirm ─────────────────────────────────────────────────────────

list_creds() {
  az ad app federated-credential list --id "${APP_OBJECT_ID}" -o json \
    | jq -c 'sort_by(.name) | .[] | {id, name, subject, issuer}'
}

show() {
  local N=0
  echo >&2
  echo "Federated credentials on the app registration:" >&2
  while IFS= read -r C; do
    N=$((N + 1))
    printf '  %2d. %-32s %s\n' "${N}" "$(jq -r .name <<<"${C}")" "$(jq -r .subject <<<"${C}")" >&2
  done <<<"$1"
  echo >&2
}

CREDS="$(list_creds)"
if [ -z "${CREDS}" ]; then
  log "no federated credentials on this app registration; nothing to remove"
  exit 0
fi

while :; do
  show "${CREDS}"
  TOTAL="$(wc -l <<<"${CREDS}" | tr -d ' ')"
  printf "Type 'DELETE CREDENTIAL <number>' to remove one, 'DELETE ALL CREDENTIALS' to remove all %s, anything else to exit: " "${TOTAL}" >&2
  read -r ANSWER </dev/tty

  if [ "${ANSWER}" = "DELETE ALL CREDENTIALS" ]; then
    while IFS= read -r C; do
      az ad app federated-credential delete --id "${APP_OBJECT_ID}" --federated-credential-id "$(jq -r .id <<<"${C}")"
      ok "removed $(jq -r .name <<<"${C}")  →  $(jq -r .subject <<<"${C}")"
    done <<<"${CREDS}"
    exit 0
  fi

  if [[ "${ANSWER}" =~ ^DELETE\ CREDENTIAL\ ([0-9]+)$ ]]; then
    IDX="${BASH_REMATCH[1]}"
    if [ "${IDX}" -lt 1 ] || [ "${IDX}" -gt "${TOTAL}" ]; then
      log "no credential number ${IDX}"
      continue
    fi
    C="$(sed -n "${IDX}p" <<<"${CREDS}")"
    az ad app federated-credential delete --id "${APP_OBJECT_ID}" --federated-credential-id "$(jq -r .id <<<"${C}")"
    ok "removed $(jq -r .name <<<"${C}")  →  $(jq -r .subject <<<"${C}")"
    CREDS="$(list_creds)"
    [ -n "${CREDS}" ] || { log "no federated credentials remain"; exit 0; }
    continue
  fi

  log "no changes made"
  exit 0
done
