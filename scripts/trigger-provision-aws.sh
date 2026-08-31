#!/usr/bin/env bash
# trigger-provision-aws.sh
# Fire the AWS - Provision & Reconcile Application Resources workflow via
# the GitHub `repository_dispatch` trigger. Each value can come from a CLI
# flag, or from the equivalent upper-case env var if the flag is omitted.
# Missing required values produce an error with the expected syntax.
#
# The target repository (where the workflow lives) is auto-detected from the
# current git remote via `gh repo view`. Override with --repo.
#
# Values are validated here as well as in the workflow. That is deliberate:
# `repository_dispatch` returns 204 as soon as the event is accepted, so a bad
# app name or role ARN would otherwise only surface a minute later, inside a
# run that has already started. Catching it locally keeps the feedback instant.
#
# Requires: `gh` authenticated (`gh auth login`) and `jq`.

set -euo pipefail

usage() {
  cat <<'USAGE' >&2
Usage:
  scripts/trigger-provision-aws.sh [flags]

Required (flag OR env var):
  --app-name            <name>                    APP_NAME
  --environment         <dev|staging|prod|all>    ENVIRONMENT
  --aws-region          <region>                  AWS_REGION
  --aws-role-arn        <arn>                     AWS_ROLE_ARN
  --main-domain         <domain>                  MAIN_DOMAIN
  --infra-template-repo <owner/name>              INFRA_TEMPLATE_REPO

Optional:
  --app-template-repo      <owner/name>  APP_TEMPLATE_REPO
                                           (default: empty — provisions
                                            infrastructure only, no app repo)
  --infra-template-ref     <ref>         INFRA_TEMPLATE_REF
                                           (tag, branch or SHA pinning the infra
                                            template; default: its default branch)
  --app-template-ref       <ref>         APP_TEMPLATE_REF
                                           (same, for the app template)
  --container-image        <ref>         CONTAINER_IMAGE
                                           (default: the workflow's reference image; ignored on
                                            reconcile runs — CodeDeploy keeps the task definition)
  --ci-workflow-file       <name>        CI_WORKFLOW_FILE
                                           (default: ci.yml)
  --repo                   <owner/name>  PLATFORM_REPO
                                           (default: auto-detected from git remote)

For help:
  -h, --help

Example:
  scripts/trigger-provision-aws.sh \
    --app-name            test-webapp \
    --environment         dev \
    --aws-region          eu-west-1 \
    --aws-role-arn        arn:aws:iam::123456789012:role/GitHubActionsRole \
    --main-domain         example.com \
    --infra-template-repo deors/template-terraform-aws-fargate \
    --app-template-repo   deors/template-helloworld-express
USAGE
}

# ── CLI parsing ──────────────────────────────────────────────────────────────
# Pre-seed each variable from its env var (if set). CLI flags override them.
APP_NAME="${APP_NAME:-}"
ENVIRONMENT="${ENVIRONMENT:-}"
AWS_REGION="${AWS_REGION:-}"
AWS_ROLE_ARN="${AWS_ROLE_ARN:-}"
MAIN_DOMAIN="${MAIN_DOMAIN:-}"
INFRA_TEMPLATE_REPO="${INFRA_TEMPLATE_REPO:-}"
INFRA_TEMPLATE_REF="${INFRA_TEMPLATE_REF:-}"
APP_TEMPLATE_REPO="${APP_TEMPLATE_REPO:-}"
APP_TEMPLATE_REF="${APP_TEMPLATE_REF:-}"
CONTAINER_IMAGE="${CONTAINER_IMAGE:-}"
CI_WORKFLOW_FILE="${CI_WORKFLOW_FILE:-}"
PLATFORM_REPO="${PLATFORM_REPO:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-name)               APP_NAME="$2";               shift 2 ;;
    --environment)            ENVIRONMENT="$2";            shift 2 ;;
    --aws-region)             AWS_REGION="$2";             shift 2 ;;
    --aws-role-arn)           AWS_ROLE_ARN="$2";           shift 2 ;;
    --main-domain)            MAIN_DOMAIN="$2";            shift 2 ;;
    --infra-template-repo)    INFRA_TEMPLATE_REPO="$2";    shift 2 ;;
    --infra-template-ref)     INFRA_TEMPLATE_REF="$2";     shift 2 ;;
    --app-template-repo)      APP_TEMPLATE_REPO="$2";      shift 2 ;;
    --app-template-ref)       APP_TEMPLATE_REF="$2";       shift 2 ;;
    --container-image)        CONTAINER_IMAGE="$2";        shift 2 ;;
    --ci-workflow-file)       CI_WORKFLOW_FILE="$2";       shift 2 ;;
    --repo)                   PLATFORM_REPO="$2";          shift 2 ;;
    -h|--help)                usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

# ── Required-value check ─────────────────────────────────────────────────────
# app_template_repo is NOT required: omitting it provisions infrastructure only,
# matching the workflow's `with_app_repo` behaviour.
MISSING=()
[[ -z "$APP_NAME"            ]] && MISSING+=("--app-name / APP_NAME")
[[ -z "$ENVIRONMENT"         ]] && MISSING+=("--environment / ENVIRONMENT")
[[ -z "$AWS_REGION"          ]] && MISSING+=("--aws-region / AWS_REGION")
[[ -z "$AWS_ROLE_ARN"        ]] && MISSING+=("--aws-role-arn / AWS_ROLE_ARN")
[[ -z "$MAIN_DOMAIN"         ]] && MISSING+=("--main-domain / MAIN_DOMAIN")
[[ -z "$INFRA_TEMPLATE_REPO" ]] && MISSING+=("--infra-template-repo / INFRA_TEMPLATE_REPO")

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "ERROR: missing required value(s):" >&2
  printf '  - %s\n' "${MISSING[@]}" >&2
  echo >&2
  usage
  exit 2
fi

# ── Value validation (mirrors the workflow's resolve-inputs job) ─────────────
INVALID=()
if ! [[ "$APP_NAME" =~ ^[a-z0-9][a-z0-9-]{1,20}[a-z0-9]$ ]]; then
  INVALID+=("app_name must be 3–22 chars, lowercase alphanumeric and hyphens, no leading/trailing hyphen — got '${APP_NAME}'")
fi
case "$ENVIRONMENT" in
  dev|staging|prod|all) ;;
  *) INVALID+=("environment must be one of: dev, staging, prod, all — got '${ENVIRONMENT}'") ;;
esac
# The workflow parses this ARN for both the account ID (which names the tfstate
# bucket) and the role name (whose trust policy gains the app's OIDC subject),
# so a malformed value silently targets the wrong thing rather than erroring.
if ! [[ "$AWS_ROLE_ARN" =~ ^arn:aws[a-z-]*:iam::[0-9]{12}:role/.+$ ]]; then
  INVALID+=("aws_role_arn must be a full IAM role ARN, e.g. arn:aws:iam::123456789012:role/GitHubActionsRole — got '${AWS_ROLE_ARN}'")
fi
if [[ ${#INVALID[@]} -gt 0 ]]; then
  echo "ERROR: invalid value(s):" >&2
  printf '  - %s\n' "${INVALID[@]}" >&2
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
# Omitted keys let the workflow apply its own defaults; sending them as empty
# strings would instead override those defaults with nothing.
PAYLOAD=$(jq -nc \
  --arg app         "$APP_NAME" \
  --arg env         "$ENVIRONMENT" \
  --arg region      "$AWS_REGION" \
  --arg role        "$AWS_ROLE_ARN" \
  --arg domain      "$MAIN_DOMAIN" \
  --arg infra_tmpl  "$INFRA_TEMPLATE_REPO" \
  --arg infra_ref   "$INFRA_TEMPLATE_REF" \
  --arg app_tmpl    "$APP_TEMPLATE_REPO" \
  --arg app_ref     "$APP_TEMPLATE_REF" \
  --arg image       "$CONTAINER_IMAGE" \
  --arg ci          "$CI_WORKFLOW_FILE" \
  '{
    event_type:     "aws-provision-infrastructure",
    client_payload: ({
      app_name:            $app,
      environment:         $env,
      aws_region:          $region,
      aws_role_arn:        $role,
      main_domain:         $domain,
      infra_template_repo: $infra_tmpl
    }
    + (if $infra_ref != "" then {infra_template_ref:     $infra_ref} else {} end)
    + (if $app_tmpl  != "" then {app_template_repo:      $app_tmpl}  else {} end)
    + (if $app_ref   != "" then {app_template_ref:       $app_ref}   else {} end)
    + (if $image     != "" then {container_image:        $image}     else {} end)
    + (if $ci        != "" then {ci_workflow_file:       $ci}        else {} end))
  }')

# ── Dispatch ─────────────────────────────────────────────────────────────────
echo "Dispatching 'aws-provision-infrastructure' to ${PLATFORM_REPO}…"
if [[ -z "$APP_TEMPLATE_REPO" ]]; then
  echo "  (no --app-template-repo: provisioning infrastructure only)"
fi
echo "$PAYLOAD" | gh api \
  --method POST \
  -H "Accept: application/vnd.github+json" \
  "repos/${PLATFORM_REPO}/dispatches" \
  --input -

echo
echo "✓ Dispatched. The workflow run will appear shortly at:"
echo "  https://github.com/${PLATFORM_REPO}/actions/workflows/provision-infrastructure-aws.yml"
