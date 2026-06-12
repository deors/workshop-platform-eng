#!/usr/bin/env bash
# tag-app-resources.sh
# Merge an arbitrary set of tags onto every Azure resource that belongs to an
# app. Resource groups are discovered by the naming conventions:
#   rg-<app_name>-<env>   (per-environment groups)
#   rg-tfstate-<app_name> (Terraform state backend)
# Uses `az tag update --operation Merge` so existing tags are preserved.
#
# Requires: az (Azure CLI), jq.

set -euo pipefail

usage() {
  cat <<'USAGE' >&2
Usage:
  scripts/tag-app-resources.sh [flags]

Required (flag OR env var):
  --app-name              <name>    APP_NAME
  --azure-tenant-id       <guid>    AZURE_TENANT_ID
  --azure-subscription-id <guid>    AZURE_SUBSCRIPTION_ID
  --azure-client-id       <guid>    AZURE_CLIENT_ID
  --tags-json             <json>    TAGS_JSON
    A JSON object whose keys and values become the tags applied to every
    resource. Example: '{"airid":"309005","Application":"myapp","CreatedBy":"user"}'

Optional (flag OR env var):
  --azure-client-secret   <secret>  AZURE_CLIENT_SECRET
    When provided, performs a service-principal login before running.
    When omitted, the existing `az login` session is used.
  --dry-run                         DRYRUN=true
    Print the tagging commands that would run without executing them.
    Resource discovery (read-only) still runs so you can preview the scope.

For help:
  -h, --help

Example:
  scripts/tag-app-resources.sh \
    --app-name               myapp \
    --azure-tenant-id        11111111-1111-1111-1111-111111111111 \
    --azure-subscription-id  b7212ffc-e49b-4c42-8c74-6efb375cf064 \
    --azure-client-id        00000000-0000-0000-0000-000000000000 \
    --tags-json              '{"airid":"309005","Application":"myapp","CreatedBy":"user"}'
USAGE
}

# ── CLI parsing ───────────────────────────────────────────────────────────────
APP_NAME="${APP_NAME:-}"
AZURE_TENANT_ID="${AZURE_TENANT_ID:-}"
AZURE_SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-}"
AZURE_CLIENT_ID="${AZURE_CLIENT_ID:-}"
AZURE_CLIENT_SECRET="${AZURE_CLIENT_SECRET:-}"
TAGS_JSON="${TAGS_JSON:-}"
DRYRUN="${DRYRUN:-false}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-name)               APP_NAME="$2";               shift 2 ;;
    --azure-tenant-id)        AZURE_TENANT_ID="$2";        shift 2 ;;
    --azure-subscription-id)  AZURE_SUBSCRIPTION_ID="$2";  shift 2 ;;
    --azure-client-id)        AZURE_CLIENT_ID="$2";        shift 2 ;;
    --azure-client-secret)    AZURE_CLIENT_SECRET="$2";    shift 2 ;;
    --tags-json)              TAGS_JSON="$2";              shift 2 ;;
    --dry-run)                DRYRUN=true;                 shift   ;;
    -h|--help)                usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

# ── Required-value check ──────────────────────────────────────────────────────
MISSING=()
[[ -z "$APP_NAME"              ]] && MISSING+=("--app-name / APP_NAME")
[[ -z "$AZURE_TENANT_ID"       ]] && MISSING+=("--azure-tenant-id / AZURE_TENANT_ID")
[[ -z "$AZURE_SUBSCRIPTION_ID" ]] && MISSING+=("--azure-subscription-id / AZURE_SUBSCRIPTION_ID")
[[ -z "$AZURE_CLIENT_ID"       ]] && MISSING+=("--azure-client-id / AZURE_CLIENT_ID")
[[ -z "$TAGS_JSON"             ]] && MISSING+=("--tags-json / TAGS_JSON")

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "ERROR: missing required value(s):" >&2
  printf '  - %s\n' "${MISSING[@]}" >&2
  echo >&2
  usage
  exit 2
fi

# ── Tooling check ─────────────────────────────────────────────────────────────
command -v az  >/dev/null || { echo "ERROR: az CLI not installed — https://learn.microsoft.com/cli/azure/install-azure-cli" >&2; exit 1; }
command -v jq  >/dev/null || { echo "ERROR: jq not installed — https://jqlang.org" >&2; exit 1; }

# ── Validate and parse tags JSON ──────────────────────────────────────────────
if ! echo "$TAGS_JSON" | jq -e 'type == "object"' >/dev/null 2>&1; then
  echo "ERROR: --tags-json must be a valid JSON object, e.g. '{\"key\":\"value\"}'" >&2
  exit 2
fi

# Build a bash array of "key=value" strings for az tag update --tags
TAGS_ARRAY=()
while IFS= read -r pair; do
  [[ -n "$pair" ]] && TAGS_ARRAY+=("$pair")
done < <(echo "$TAGS_JSON" | jq -r 'to_entries[] | "\(.key)=\(.value)"')

if [[ ${#TAGS_ARRAY[@]} -eq 0 ]]; then
  echo "ERROR: --tags-json object has no keys; nothing to apply." >&2
  exit 2
fi

echo "Tags to apply (${#TAGS_ARRAY[@]}):"
printf '  %s\n' "${TAGS_ARRAY[@]}"

# ── Helpers ───────────────────────────────────────────────────────────────────

# Apply the tags to a resource ID, merging with any existing tags.
# Skips (with a warning) resource types that don't support tagging.
tag_resource() {
  local resource_id="$1"
  local label="$2"

  if [[ "$DRYRUN" == "true" ]]; then
    echo "  [dry-run] tag: ${label}"
    return
  fi

  if az tag update \
      --resource-id "$resource_id" \
      --operation Merge \
      --tags "${TAGS_ARRAY[@]}" \
      --output none 2>/tmp/tag-err; then
    echo "  tagged:   ${label}"
  else
    echo "  WARNING: could not tag ${label}: $(cat /tmp/tag-err)" >&2
  fi
}

# ── Authentication ────────────────────────────────────────────────────────────
if [[ -n "$AZURE_CLIENT_SECRET" ]]; then
  echo "Logging in as service principal ${AZURE_CLIENT_ID}…"
  az login --service-principal \
    --tenant "$AZURE_TENANT_ID" \
    --username "$AZURE_CLIENT_ID" \
    --password "$AZURE_CLIENT_SECRET" \
    --output none
fi

echo "Setting subscription ${AZURE_SUBSCRIPTION_ID}…"
az account set --subscription "$AZURE_SUBSCRIPTION_ID"

# ── Discover resource groups ──────────────────────────────────────────────────
echo
echo "Discovering resource groups for app '${APP_NAME}'…"

RGS=()
while IFS= read -r rg; do
  [[ -n "$rg" ]] && RGS+=("$rg")
done < <(az group list \
  --query "[?starts_with(name, 'rg-${APP_NAME}-') || name == 'rg-tfstate-${APP_NAME}'].name" \
  --output tsv | sort)

if [[ ${#RGS[@]} -eq 0 ]]; then
  echo "No resource groups found matching 'rg-${APP_NAME}-*' or 'rg-tfstate-${APP_NAME}'. Nothing to do."
  exit 0
fi

echo "Found ${#RGS[@]} resource group(s):"
printf '  %s\n' "${RGS[@]}"
echo

[[ "$DRYRUN" == "true" ]] && echo "[dry-run mode — no tags will be written]" && echo

# ── Tag each resource group and its resources ─────────────────────────────────
TOTAL_RGS=0
TOTAL_RESOURCES=0

for RG in "${RGS[@]}"; do
  echo "── ${RG} $(printf '%.0s─' {1..50})"

  RG_ID="/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${RG}"
  tag_resource "$RG_ID" "(resource group) ${RG}"
  [[ "$DRYRUN" != "true" ]] && (( TOTAL_RGS++ )) || true

  RESOURCE_IDS=()
  while IFS= read -r rid; do
    [[ -n "$rid" ]] && RESOURCE_IDS+=("$rid")
  done < <(az resource list \
    --resource-group "$RG" \
    --query "[].id" \
    --output tsv)

  if [[ ${#RESOURCE_IDS[@]} -eq 0 ]]; then
    echo "  (no resources)"
  else
    for RESOURCE_ID in "${RESOURCE_IDS[@]}"; do
      SHORT="${RESOURCE_ID##*/}"
      tag_resource "$RESOURCE_ID" "${SHORT}"
      [[ "$DRYRUN" != "true" ]] && (( TOTAL_RESOURCES++ )) || true
    done
  fi

  echo
done

if [[ "$DRYRUN" == "true" ]]; then
  echo "Dry run complete. No tags were written."
else
  echo "Done. Tagged ${TOTAL_RGS} resource group(s) and ${TOTAL_RESOURCES} resource(s)."
fi
