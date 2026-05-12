#!/usr/bin/env bash
# trigger-provision.sh
# Fire the Provision Infrastructure workflow via the GitHub `repository_dispatch`
# trigger. Each value can come from a CLI flag, or from the equivalent
# upper-case env var if the flag is omitted. Missing required values produce
# an error with the expected syntax.
#
# The target repository (where the workflow lives) is auto-detected from the
# current git remote via `gh repo view`. Override with --repo.
#
# Requires: `gh` authenticated (`gh auth login`) and `jq`.

set -euo pipefail

usage() {
  cat <<'USAGE' >&2
Usage:
  scripts/trigger-provision.sh [flags]

Required (flag OR env var):
  --environment      <dev|staging|prod|all>    ENVIRONMENT
  --app-name         <name>                    APP_NAME
  --subscription-id  <guid>                    SUBSCRIPTION_ID
  --azure-client-id  <guid>                    AZURE_CLIENT_ID
  --azure-tenant-id  <guid>                    AZURE_TENANT_ID
  --template-repo    <owner/name>              TEMPLATE_REPO

Optional:
  --container-image        <ref>     CONTAINER_IMAGE
                                       (default: mcr.microsoft.com/appsvc/staticsite:latest;
                                        a placeholder that App Service can pull anonymously —
                                        the template's CI overwrites it within minutes; ignored
                                        on reconcile runs)
  --container-registry-url <url>     CONTAINER_REGISTRY_URL
                                       (default: empty)
  --ci-workflow-file       <name>    CI_WORKFLOW_FILE
                                       (default: ci.yml)
  --event-type             <type>    EVENT_TYPE
                                       (default: provision-infrastructure;
                                        also valid: update-infrastructure)
  --repo                   <owner/name>  PLATFORM_REPO
                                       (default: auto-detected from git remote)
  -h, --help                            show this help

Example:
  scripts/trigger-provision.sh \
    --environment      dev \
    --app-name         test-webapp \
    --subscription-id  b7212ffc-e49b-4c42-8c74-6efb375cf064 \
    --azure-client-id  00000000-0000-0000-0000-000000000000 \
    --azure-tenant-id  11111111-1111-1111-1111-111111111111 \
    --template-repo    deors/template-helloworld-express
USAGE
}

# ── CLI parsing ──────────────────────────────────────────────────────────────
# Pre-seed each variable from its env var (if set). CLI flags override them.
ENVIRONMENT="${ENVIRONMENT:-}"
APP_NAME="${APP_NAME:-}"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-}"
AZURE_CLIENT_ID="${AZURE_CLIENT_ID:-}"
AZURE_TENANT_ID="${AZURE_TENANT_ID:-}"
TEMPLATE_REPO="${TEMPLATE_REPO:-}"
CONTAINER_IMAGE="${CONTAINER_IMAGE:-}"
CONTAINER_REGISTRY_URL="${CONTAINER_REGISTRY_URL:-}"
CI_WORKFLOW_FILE="${CI_WORKFLOW_FILE:-}"
EVENT_TYPE="${EVENT_TYPE:-provision-infrastructure}"
PLATFORM_REPO="${PLATFORM_REPO:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --environment)            ENVIRONMENT="$2";            shift 2 ;;
    --app-name)               APP_NAME="$2";               shift 2 ;;
    --subscription-id)        SUBSCRIPTION_ID="$2";        shift 2 ;;
    --azure-client-id)        AZURE_CLIENT_ID="$2";        shift 2 ;;
    --azure-tenant-id)        AZURE_TENANT_ID="$2";        shift 2 ;;
    --template-repo)          TEMPLATE_REPO="$2";          shift 2 ;;
    --container-image)        CONTAINER_IMAGE="$2";        shift 2 ;;
    --container-registry-url) CONTAINER_REGISTRY_URL="$2"; shift 2 ;;
    --ci-workflow-file)       CI_WORKFLOW_FILE="$2";       shift 2 ;;
    --event-type)             EVENT_TYPE="$2";             shift 2 ;;
    --repo)                   PLATFORM_REPO="$2";          shift 2 ;;
    -h|--help)                usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

# ── Required-value check ─────────────────────────────────────────────────────
MISSING=()
[[ -z "$ENVIRONMENT"     ]] && MISSING+=("--environment / ENVIRONMENT")
[[ -z "$APP_NAME"        ]] && MISSING+=("--app-name / APP_NAME")
[[ -z "$SUBSCRIPTION_ID" ]] && MISSING+=("--subscription-id / SUBSCRIPTION_ID")
[[ -z "$AZURE_CLIENT_ID" ]] && MISSING+=("--azure-client-id / AZURE_CLIENT_ID")
[[ -z "$AZURE_TENANT_ID" ]] && MISSING+=("--azure-tenant-id / AZURE_TENANT_ID")
[[ -z "$TEMPLATE_REPO"   ]] && MISSING+=("--template-repo / TEMPLATE_REPO")

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "ERROR: missing required value(s):" >&2
  printf '  - %s\n' "${MISSING[@]}" >&2
  echo >&2
  usage
  exit 2
fi

# ── Tooling check ────────────────────────────────────────────────────────────
command -v gh >/dev/null || { echo "ERROR: gh CLI not installed (https://cli.github.com)" >&2; exit 1; }
command -v jq >/dev/null || { echo "ERROR: jq not installed" >&2; exit 1; }

# ── Auto-detect the target repo when not provided ────────────────────────────
if [[ -z "$PLATFORM_REPO" ]]; then
  PLATFORM_REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
fi
if [[ -z "$PLATFORM_REPO" ]]; then
  echo "ERROR: could not detect platform repo from git remote; pass --repo or set PLATFORM_REPO" >&2
  exit 1
fi

# ── Build the client_payload (omit empty optional fields) ────────────────────
PAYLOAD=$(jq -nc \
  --arg event "$EVENT_TYPE" \
  --arg env   "$ENVIRONMENT" \
  --arg app   "$APP_NAME" \
  --arg sub   "$SUBSCRIPTION_ID" \
  --arg cid   "$AZURE_CLIENT_ID" \
  --arg tid   "$AZURE_TENANT_ID" \
  --arg tmpl  "$TEMPLATE_REPO" \
  --arg image "$CONTAINER_IMAGE" \
  --arg reg   "$CONTAINER_REGISTRY_URL" \
  --arg ci    "$CI_WORKFLOW_FILE" \
  '{
    event_type:     $event,
    client_payload: ({
      environment:     $env,
      app_name:        $app,
      subscription_id: $sub,
      azure_client_id: $cid,
      azure_tenant_id: $tid,
      template_repo:   $tmpl
    }
    + (if $image != "" then {container_image:        $image} else {} end)
    + (if $reg   != "" then {container_registry_url: $reg}   else {} end)
    + (if $ci    != "" then {ci_workflow_file:       $ci}    else {} end))
  }')

# ── Dispatch ─────────────────────────────────────────────────────────────────
echo "Dispatching '${EVENT_TYPE}' to ${PLATFORM_REPO}…"
echo "$PAYLOAD" | gh api \
  --method POST \
  -H "Accept: application/vnd.github+json" \
  "repos/${PLATFORM_REPO}/dispatches" \
  --input -

echo
echo "✓ Dispatched. The workflow run will appear shortly at:"
echo "  https://github.com/${PLATFORM_REPO}/actions/workflows/provision-infrastructure.yml"
