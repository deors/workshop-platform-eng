#!/usr/bin/env bash
# bootstrap-tfstate.sh
# Creates (idempotently) the Azure Storage Account used as Terraform remote backend.
# One storage account per subscription + application; one blob per environment inside it.
#
# Usage:
#   bootstrap-tfstate.sh --app-name <name> --subscription-id <id> \
#                        [--location <region>] [--principal-id <object-id>]
#
# Outputs (stdout, last lines):
#   TFSTATE_RESOURCE_GROUP=rg-tfstate-<app>
#   TFSTATE_STORAGE_ACCOUNT=sttf<app12><sub8>
#   TFSTATE_CONTAINER=tfstate

set -euo pipefail

# ── Helpers ──────────────────────────────────────────────────────────────────

log()  { echo "[bootstrap-tfstate] $*" >&2; }
err()  { echo "[bootstrap-tfstate] ERROR: $*" >&2; exit 1; }
ok()   { echo "[bootstrap-tfstate] ✓ $*" >&2; }
skip() { echo "[bootstrap-tfstate] → $*" >&2; }

# ── Argument parsing ──────────────────────────────────────────────────────────

APP_NAME=""
SUBSCRIPTION_ID=""
LOCATION="westeurope"
PRINCIPAL_ID=""      # optional: object ID to assign Storage Blob Data Contributor

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-name)        APP_NAME="$2";       shift 2 ;;
    --subscription-id) SUBSCRIPTION_ID="$2"; shift 2 ;;
    --location)        LOCATION="$2";       shift 2 ;;
    --principal-id)    PRINCIPAL_ID="$2";   shift 2 ;;
    *) err "Unknown argument: $1" ;;
  esac
done

[[ -z "$APP_NAME"        ]] && err "--app-name is required"
[[ -z "$SUBSCRIPTION_ID" ]] && err "--subscription-id is required"

# ── Name derivation ───────────────────────────────────────────────────────────
# Storage account names: 3-24 chars, lowercase alphanumeric only, globally unique.
# Formula: sttf + first 12 chars of app_name (no hyphens) + first 8 chars of sub ID (no hyphens)
# Total: 4 + 12 + 8 = 24 chars exactly.

APP_SHORT=$(echo "$APP_NAME"        | tr -d '-' | tr '[:upper:]' '[:lower:]' | cut -c1-12)
SUB_SHORT=$(echo "$SUBSCRIPTION_ID" | tr -d '-'                               | cut -c1-8)

STORAGE_ACCOUNT_NAME="sttf${APP_SHORT}${SUB_SHORT}"
RESOURCE_GROUP_NAME="rg-tfstate-${APP_NAME}"
CONTAINER_NAME="tfstate"

log "App name      : $APP_NAME"
log "Subscription  : $SUBSCRIPTION_ID"
log "Location      : $LOCATION"
log "Resource group: $RESOURCE_GROUP_NAME"
log "Storage acct  : $STORAGE_ACCOUNT_NAME"
log "Container     : $CONTAINER_NAME"
[[ -n "$PRINCIPAL_ID" ]] && log "Principal ID  : $PRINCIPAL_ID"

# ── Prerequisite check ────────────────────────────────────────────────────────

command -v az &>/dev/null || err "Azure CLI not found. Install from https://aka.ms/azure-cli"

# ── Set active subscription ───────────────────────────────────────────────────

log "Setting active subscription…"
az account set --subscription "$SUBSCRIPTION_ID"
ok "Subscription set"

# ── Resource group ────────────────────────────────────────────────────────────

log "Checking resource group '$RESOURCE_GROUP_NAME'…"
if az group show --name "$RESOURCE_GROUP_NAME" --output none 2>/dev/null; then
  skip "Resource group already exists"
else
  log "Creating resource group…"
  az group create \
    --name     "$RESOURCE_GROUP_NAME" \
    --location "$LOCATION" \
    --tags     "managed-by=bootstrap-tfstate" "platform=platform-engineering" \
    --output none
  ok "Resource group created"
fi

# ── Storage account ───────────────────────────────────────────────────────────

log "Checking storage account '$STORAGE_ACCOUNT_NAME'…"
if az storage account show \
     --name                "$STORAGE_ACCOUNT_NAME" \
     --resource-group      "$RESOURCE_GROUP_NAME" \
     --output none 2>/dev/null; then
  skip "Storage account already exists — enforcing security settings"
  ACCOUNT_EXISTS=true
else
  log "Creating storage account…"
  ACCOUNT_EXISTS=false
fi

if [[ "$ACCOUNT_EXISTS" == false ]]; then
  az storage account create \
    --name                "$STORAGE_ACCOUNT_NAME" \
    --resource-group      "$RESOURCE_GROUP_NAME" \
    --location            "$LOCATION" \
    --sku                 Standard_LRS \
    --kind                StorageV2 \
    --access-tier         Hot \
    --min-tls-version     TLS1_2 \
    --https-only          true \
    --allow-blob-public-access false \
    --allow-shared-key-access  false \
    --default-action      Deny \
    --bypass              AzureServices \
    --tags                "managed-by=bootstrap-tfstate" "platform=platform-engineering" \
    --output none
  ok "Storage account created"
fi

# Enforce security settings idempotently (catches existing accounts created without them)
log "Enforcing storage account security settings…"
az storage account update \
  --name                "$STORAGE_ACCOUNT_NAME" \
  --resource-group      "$RESOURCE_GROUP_NAME" \
  --min-tls-version     TLS1_2 \
  --https-only          true \
  --allow-blob-public-access false \
  --allow-shared-key-access  false \
  --output none
ok "Security settings enforced"

# ── Blob versioning + soft-delete (state recovery) ────────────────────────────

log "Configuring blob versioning and soft-delete…"
az storage account blob-service-properties update \
  --account-name              "$STORAGE_ACCOUNT_NAME" \
  --resource-group            "$RESOURCE_GROUP_NAME" \
  --enable-versioning         true \
  --enable-delete-retention   true \
  --delete-retention-days     30 \
  --enable-container-delete-retention true \
  --container-delete-retention-days   7 \
  --output none
ok "Versioning and soft-delete configured (30-day retention)"

# ── Container ─────────────────────────────────────────────────────────────────

log "Checking container '$CONTAINER_NAME'…"
CONTAINER_EXISTS=$(az storage container exists \
  --name         "$CONTAINER_NAME" \
  --account-name "$STORAGE_ACCOUNT_NAME" \
  --auth-mode    login \
  --query        "exists" \
  --output       tsv 2>/dev/null)

if [[ "$CONTAINER_EXISTS" == "true" ]]; then
  skip "Container already exists"
else
  log "Creating container…"
  az storage container create \
    --name         "$CONTAINER_NAME" \
    --account-name "$STORAGE_ACCOUNT_NAME" \
    --auth-mode    login \
    --output none
  ok "Container created"
fi

# ── RBAC – Storage Blob Data Contributor ─────────────────────────────────────

if [[ -n "$PRINCIPAL_ID" ]]; then
  SCOPE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP_NAME}/providers/Microsoft.Storage/storageAccounts/${STORAGE_ACCOUNT_NAME}"
  ROLE="Storage Blob Data Contributor"

  log "Checking role assignment '${ROLE}' for principal '${PRINCIPAL_ID}'…"
  EXISTING=$(az role assignment list \
    --assignee "$PRINCIPAL_ID" \
    --role     "$ROLE" \
    --scope    "$SCOPE" \
    --query    "[0].id" \
    --output   tsv 2>/dev/null)

  if [[ -n "$EXISTING" ]]; then
    skip "Role assignment already exists"
  else
    log "Assigning '${ROLE}'…"
    az role assignment create \
      --assignee-object-id  "$PRINCIPAL_ID" \
      --assignee-principal-type ServicePrincipal \
      --role     "$ROLE" \
      --scope    "$SCOPE" \
      --output none
    ok "Role assignment created"
  fi
fi

# ── Output ────────────────────────────────────────────────────────────────────

log "Bootstrap complete."
echo "TFSTATE_RESOURCE_GROUP=${RESOURCE_GROUP_NAME}"
echo "TFSTATE_STORAGE_ACCOUNT=${STORAGE_ACCOUNT_NAME}"
echo "TFSTATE_CONTAINER=${CONTAINER_NAME}"
