#!/usr/bin/env bash
# tag-app-resources-aws.sh
# Merge an arbitrary set of tags onto every AWS resource that belongs to an
# app. Resource groups are discovered by the naming conventions:
#   rg-<app_name>-<env>     (per-environment groups)
#   rg-<app_name>-tfstate   (Terraform state backend)
# Uses the Resource Groups Tagging API so existing tags are preserved (merge semantics).
#
# Requires: aws (AWS CLI v2), jq.
# AWS credentials must be pre-configured (environment variables, instance
# profile, named profile, or the configure-aws-credentials GitHub Action).

set -euo pipefail

usage() {
  cat <<'USAGE' >&2
Usage:
  scripts/tag-app-resources-aws.sh [flags]

Required (flag OR env var):
  --app-name   <name>   APP_NAME
  --tags-json  <json>   TAGS_JSON
    A JSON object whose keys and values become the tags applied to every
    resource. Example: '{"AppId":"12345","Application":"myapp","CreatedBy":"user"}'

Optional (flag OR env var):
  --aws-region <region> AWS_REGION
    AWS region. Falls back to AWS_DEFAULT_REGION if not set.
  --dry-run             DRYRUN=true
    Print the tagging commands that would run without executing them.
    Resource discovery (read-only) still runs so you can preview the scope.

For help:
  -h, --help

Example:
  scripts/tag-app-resources-aws.sh \
    --app-name  myapp \
    --aws-region us-east-1 \
    --tags-json '{"AppId":"12345","Application":"myapp","CreatedBy":"user"}'
USAGE
}

# ── CLI parsing ───────────────────────────────────────────────────────────────
APP_NAME="${APP_NAME:-}"
AWS_REGION="${AWS_REGION:-}"
TAGS_JSON="${TAGS_JSON:-}"
DRYRUN="${DRYRUN:-false}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-name)   APP_NAME="$2";   shift 2 ;;
    --aws-region) AWS_REGION="$2"; shift 2 ;;
    --tags-json)  TAGS_JSON="$2";  shift 2 ;;
    --dry-run)    DRYRUN=true;     shift   ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

# ── Required-value check ──────────────────────────────────────────────────────
MISSING=()
[[ -z "$APP_NAME"  ]] && MISSING+=("--app-name / APP_NAME")
[[ -z "$TAGS_JSON" ]] && MISSING+=("--tags-json / TAGS_JSON")

# Resolve region: flag → env var → AWS_DEFAULT_REGION (set by configure-aws-credentials)
if [[ -n "$AWS_REGION" ]]; then
  export AWS_DEFAULT_REGION="$AWS_REGION"
fi
if [[ -z "${AWS_DEFAULT_REGION:-}" ]]; then
  MISSING+=("--aws-region / AWS_REGION or AWS_DEFAULT_REGION")
fi

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "ERROR: missing required value(s):" >&2
  printf '  - %s\n' "${MISSING[@]}" >&2
  echo >&2
  usage
  exit 2
fi

# ── Tooling check ─────────────────────────────────────────────────────────────
command -v aws >/dev/null || { echo "ERROR: aws CLI not installed — https://aws.amazon.com/cli/" >&2; exit 1; }
command -v jq  >/dev/null || { echo "ERROR: jq not installed — https://jqlang.org" >&2; exit 1; }

# ── Validate and parse tags JSON ──────────────────────────────────────────────
if ! echo "$TAGS_JSON" | jq -e 'type == "object"' >/dev/null 2>&1; then
  echo "ERROR: --tags-json must be a valid JSON object, e.g. '{\"key\":\"value\"}'" >&2
  exit 2
fi

TAG_COUNT=$(echo "$TAGS_JSON" | jq 'length')
if [[ "$TAG_COUNT" -eq 0 ]]; then
  echo "ERROR: --tags-json object has no keys; nothing to apply." >&2
  exit 2
fi

echo "Tags to apply ($TAG_COUNT):"
echo "$TAGS_JSON" | jq -r 'to_entries[] | "  \(.key)=\(.value)"'

# ── Helpers ───────────────────────────────────────────────────────────────────

# Apply the tags to a resource ARN, merging with any existing tags.
# The Tagging API returns a FailedResourcesMap for resources that cannot be
# tagged; those are reported as warnings and do not fail the run.
tag_resource() {
  local arn="$1"
  local label="$2"

  if [[ "$DRYRUN" == "true" ]]; then
    echo "  [dry-run] tag: ${label}"
    return
  fi

  local result failed_count
  if result=$(aws resourcegroupstaggingapi tag-resources \
      --region "$AWS_DEFAULT_REGION" \
      --resource-arn-list "$arn" \
      --tags "$TAGS_JSON" \
      --output json 2>/tmp/tag-err); then
    failed_count=$(echo "$result" | jq '.FailedResourcesMap | length')
    if [[ "$failed_count" -gt 0 ]]; then
      local reason
      reason=$(echo "$result" | jq -r --arg arn "$arn" \
        '.FailedResourcesMap[$arn].ErrorMessage // "unknown error"')
      echo "  WARNING: could not tag ${label}: ${reason}" >&2
    else
      echo "  tagged:   ${label}"
    fi
  else
    echo "  WARNING: could not tag ${label}: $(cat /tmp/tag-err)" >&2
  fi
}

# ── Discover resource groups ──────────────────────────────────────────────────
echo
echo "Discovering resource groups for app '${APP_NAME}'…"

# Capture into a variable and check the exit status BEFORE parsing. Reading the
# AWS call directly from a process substitution would hide its failure: `set -e`
# does not see exit codes inside `< <(...)`, so an error message would flow into
# jq and its output would be consumed as if it were a list of group names.
if ! GROUPS_RAW=$(aws resource-groups list-groups \
    --region "$AWS_DEFAULT_REGION" --output json 2>&1); then
  echo "ERROR: could not list resource groups in ${AWS_DEFAULT_REGION}:" >&2
  printf '%s\n' "$GROUPS_RAW" >&2
  exit 1
fi

# Guard the shape too, so a valid-but-unexpected response cannot be misparsed.
if ! jq -e '(.GroupIdentifiers | type) == "array"' >/dev/null 2>&1 <<<"$GROUPS_RAW"; then
  echo "ERROR: unexpected list-groups response (no GroupIdentifiers array):" >&2
  printf '%s\n' "$GROUPS_RAW" | head -20 >&2
  exit 1
fi

# `GroupIdentifiers` carries the name AND the ARN, and is the documented field —
# the sibling `Groups` array is deprecated. Taking the ARN from here also spares
# a `get-group` call per group.
GROUP_NAMES=()
GROUP_ARNS=()
while IFS=$'\t' read -r g_name g_arn; do
  [[ -z "$g_name" ]] && continue
  GROUP_NAMES+=("$g_name")
  GROUP_ARNS+=("$g_arn")
done < <(jq -r --arg name "$APP_NAME" '
  .GroupIdentifiers
  | map(select(.GroupName | startswith("rg-\($name)-")))
  | sort_by(.GroupName)[]
  | "\(.GroupName)\t\(.GroupArn)"' <<<"$GROUPS_RAW")

if [[ ${#GROUP_NAMES[@]} -eq 0 ]]; then
  echo "No resource groups found matching 'rg-${APP_NAME}-*' in ${AWS_DEFAULT_REGION}."
  echo "Resource Groups is a regional service — check that --aws-region points at"
  echo "the region holding the app's resources. Nothing to do."
  exit 0
fi

echo "Found ${#GROUP_NAMES[@]} resource group(s) in ${AWS_DEFAULT_REGION}:"
printf '  %s\n' "${GROUP_NAMES[@]}"
echo

[[ "$DRYRUN" == "true" ]] && echo "[dry-run mode — no tags will be written]" && echo

# ── Tag each resource group and its resources ─────────────────────────────────
TOTAL_GROUPS=0
TOTAL_RESOURCES=0

for i in "${!GROUP_NAMES[@]}"; do
  GROUP="${GROUP_NAMES[$i]}"
  echo "── ${GROUP} $(printf '%.0s─' {1..50})"

  tag_resource "${GROUP_ARNS[$i]}" "(resource group) ${GROUP}"
  [[ "$DRYRUN" != "true" ]] && (( TOTAL_GROUPS++ )) || true

  # Same capture-then-check discipline as the discovery call above.
  if ! MEMBERS_RAW=$(aws resource-groups list-group-resources \
      --region "$AWS_DEFAULT_REGION" --group-name "$GROUP" --output json 2>&1); then
    echo "  WARNING: could not list resources of ${GROUP}:" >&2
    printf '    %s\n' "$MEMBERS_RAW" >&2
    echo
    continue
  fi

  RESOURCE_ARNS=()
  while IFS= read -r arn; do
    [[ -n "$arn" ]] && RESOURCE_ARNS+=("$arn")
  done < <(jq -r '.Resources[]?.Identifier.ResourceArn // empty' <<<"$MEMBERS_RAW")

  if [[ ${#RESOURCE_ARNS[@]} -eq 0 ]]; then
    echo "  (no resources)"
  else
    for ARN in "${RESOURCE_ARNS[@]}"; do
      # Drop the `arn:<partition>:<service>:<region>:<account>:` prefix and keep
      # the whole resource part. Keeping only the last colon-segment would
      # reduce e.g. `task-definition/test-webapp-dev:2` to a bare `2`.
      SHORT="${ARN#arn:*:*:*:*:}"
      tag_resource "$ARN" "${SHORT}"
      [[ "$DRYRUN" != "true" ]] && (( TOTAL_RESOURCES++ )) || true
    done
  fi

  echo
done

if [[ "$DRYRUN" == "true" ]]; then
  echo "Dry run complete. No tags were written."
else
  echo "Done. Tagged ${TOTAL_GROUPS} resource group(s) and ${TOTAL_RESOURCES} resource(s)."
fi
