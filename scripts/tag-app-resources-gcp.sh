#!/usr/bin/env bash
# tag-app-resources-gcp.sh
# Merge an arbitrary set of labels onto every GCP resource that belongs to an
# app. GCP has no resource-group container: resources are discovered by the
# `application` and `environment` labels the template sets on everything
# labelable, and tagged grouped by environment:
#   application=<app_name>, environment=<env>   (dev / staging / prod, and the
#                                                Terraform state bucket's own)
# Resources carrying the application label but no environment label are
# reported and skipped. Existing labels are preserved (merge semantics).
#
# Covered types: Cloud Run services, Artifact Registry repositories,
# Certificate Manager certificates and DNS authorizations, compute addresses
# and forwarding rules, Cloud DNS managed zones, Cloud Monitoring alert
# policies (user labels) and Cloud Storage buckets. Types without label
# support (networks, subnets, firewalls, service accounts…) are not taggable.
#
# Requires: gcloud (Google Cloud CLI), jq, curl.
# Credentials must be pre-configured (`gcloud auth login`, a service account,
# or the google-github-actions/auth GitHub Action).

set -euo pipefail

usage() {
  cat <<'USAGE' >&2
Usage:
  scripts/tag-app-resources-gcp.sh [flags]

Required (flag OR env var):
  --app-name        <name>     APP_NAME
  --gcp-project-id  <project>  GCP_PROJECT_ID
  --tags-json       <json>     TAGS_JSON
    A JSON object whose keys and values become the labels applied to every
    resource. Example: '{"AppId":"12345","Application":"myapp","CreatedBy":"user"}'
    Keys and values are lowercased to meet GCP label rules (AppId → appid);
    after that, keys must start with a letter and both may contain only
    lowercase letters, digits, '_' and '-' (max 63 chars). The `application`
    key, if present, must equal the app name, and the `environment` key is
    not accepted: resources are discovered and grouped by those two labels.

Optional (flag OR env var):
  --gcp-region      <region>   GCP_REGION
    Limit discovery to one region (global resources are always included).
    When omitted, every region is searched.
  --dry-run                    DRYRUN=true
    Print the resources that would be tagged without writing any label.
    Resource discovery (read-only) still runs so you can preview the scope.

For help:
  -h, --help

Example:
  scripts/tag-app-resources-gcp.sh \
    --app-name       myapp \
    --gcp-project-id my-project-123 \
    --tags-json      '{"AppId":"12345","Application":"myapp","CreatedBy":"user"}'
USAGE
}

# ── CLI parsing ───────────────────────────────────────────────────────────────
APP_NAME="${APP_NAME:-}"
GCP_PROJECT_ID="${GCP_PROJECT_ID:-}"
GCP_REGION="${GCP_REGION:-}"
TAGS_JSON="${TAGS_JSON:-}"
DRYRUN="${DRYRUN:-false}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-name)       APP_NAME="$2";       shift 2 ;;
    --gcp-project-id) GCP_PROJECT_ID="$2"; shift 2 ;;
    --gcp-region)     GCP_REGION="$2";     shift 2 ;;
    --tags-json)      TAGS_JSON="$2";      shift 2 ;;
    --dry-run)        DRYRUN=true;         shift   ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

# ── Required-value check ──────────────────────────────────────────────────────
MISSING=()
[[ -z "$APP_NAME"       ]] && MISSING+=("--app-name / APP_NAME")
[[ -z "$GCP_PROJECT_ID" ]] && MISSING+=("--gcp-project-id / GCP_PROJECT_ID")
[[ -z "$TAGS_JSON"      ]] && MISSING+=("--tags-json / TAGS_JSON")

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "ERROR: missing required value(s):" >&2
  printf '  - %s\n' "${MISSING[@]}" >&2
  echo >&2
  usage
  exit 2
fi

# ── Tooling check ─────────────────────────────────────────────────────────────
command -v gcloud >/dev/null || { echo "ERROR: gcloud CLI not installed — https://cloud.google.com/sdk/docs/install" >&2; exit 1; }
command -v jq     >/dev/null || { echo "ERROR: jq not installed — https://jqlang.org" >&2; exit 1; }
command -v curl   >/dev/null || { echo "ERROR: curl not installed" >&2; exit 1; }

# ── Validate and parse tags JSON ──────────────────────────────────────────────
if ! echo "$TAGS_JSON" | jq -e 'type == "object"' >/dev/null 2>&1; then
  echo "ERROR: --tags-json must be a valid JSON object, e.g. '{\"key\":\"value\"}'" >&2
  exit 2
fi

# GCP labels are lowercase strings: keys and values are lowercased, and
# numbers and booleans stringified.
NORMALIZE='to_entries | map({key: (.key | ascii_downcase), value: (.value | tostring | ascii_downcase)})'

COLLISIONS=$(echo "$TAGS_JSON" | jq -r "
  to_entries | group_by(.key | ascii_downcase)[] | select(length > 1)
  | \"  \" + (map(.key) | join(\", \"))")
if [[ -n "$COLLISIONS" ]]; then
  echo "ERROR: these --tags-json keys collide once lowercased:" >&2
  printf '%s\n' "$COLLISIONS" >&2
  exit 2
fi

LABELS_JSON=$(echo "$TAGS_JSON" | jq -c "${NORMALIZE} | from_entries")

RENAMED=$(echo "$TAGS_JSON" | jq -r '
  to_entries[]
  | (.value | tostring) as $v
  | select(.key != (.key | ascii_downcase) or $v != ($v | ascii_downcase))
  | "  \(.key)=\($v) → \(.key | ascii_downcase)=\($v | ascii_downcase)"')
if [[ -n "$RENAMED" ]]; then
  echo "Normalized to GCP label rules:"
  printf '%s\n' "$RENAMED"
fi

TAG_COUNT=$(echo "$LABELS_JSON" | jq 'length')
if [[ "$TAG_COUNT" -eq 0 ]]; then
  echo "ERROR: --tags-json object has no keys; nothing to apply." >&2
  exit 2
fi
if [[ "$TAG_COUNT" -gt 64 ]]; then
  echo "ERROR: --tags-json has ${TAG_COUNT} keys; GCP allows at most 64 labels per resource." >&2
  exit 2
fi

INVALID=$(echo "$LABELS_JSON" | jq -r '
  to_entries[]
  | select((.key | test("^[a-z][a-z0-9_-]{0,62}$") | not)
        or (.value | test("^[a-z0-9_-]{0,63}$") | not))
  | "  \(.key)=\(.value)"')
if [[ -n "$INVALID" ]]; then
  echo "ERROR: these entries are not valid GCP labels, even after lowercasing:" >&2
  printf '%s\n' "$INVALID" >&2
  echo "Keys must start with a letter; keys and values may contain only letters," >&2
  echo "digits, '_' and '-', up to 63 characters." >&2
  exit 2
fi

if ! echo "$LABELS_JSON" | jq -e --arg app "$APP_NAME" \
    '(has("application") | not) or .application == $app' >/dev/null; then
  echo "ERROR: --tags-json sets 'application' to a value other than '${APP_NAME}'." >&2
  echo "Resources are discovered by that label; changing it would orphan them." >&2
  exit 2
fi
if echo "$LABELS_JSON" | jq -e 'has("environment")' >/dev/null; then
  echo "ERROR: --tags-json must not set 'environment': it differs per environment" >&2
  echo "and resources are grouped by it." >&2
  exit 2
fi

# Comma-separated KEY=VALUE list for gcloud --update-labels (values cannot
# contain commas once validated).
LABELS_ARG=$(echo "$LABELS_JSON" | jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")')

echo "Labels to apply (${TAG_COUNT}):"
echo "$LABELS_JSON" | jq -r 'to_entries[] | "  \(.key)=\(.value)"'

ERR_FILE=$(mktemp)
trap 'rm -f "$ERR_FILE"' EXIT

# ── Verify the target project ─────────────────────────────────────────────────
echo
echo "Verifying access to project ${GCP_PROJECT_ID}…"
if ! RESOLVED_PROJECT=$(gcloud projects describe "$GCP_PROJECT_ID" \
    --format='value(projectId)' 2>"$ERR_FILE"); then
  echo "ERROR: cannot access project ${GCP_PROJECT_ID}:" >&2
  cat "$ERR_FILE" >&2
  exit 1
fi
if [[ "$RESOLVED_PROJECT" != "$GCP_PROJECT_ID" ]]; then
  echo "ERROR: project lookup returned '${RESOLVED_PROJECT}', expected '${GCP_PROJECT_ID}'." >&2
  exit 1
fi
echo "Project: ${RESOLVED_PROJECT} (as $(gcloud config get-value account 2>/dev/null || echo unknown))"
echo "Region:  ${GCP_REGION:-all}"

# ── Helpers ───────────────────────────────────────────────────────────────────

# Inventory of discovered resources, one per line:
#   <environment> US <type> US <name> US <location> US <display name>
# separated by the ASCII unit separator (\037): unlike TAB it is not IFS
# whitespace, so `read` keeps empty fields in place.
INVENTORY=$(mktemp)
trap 'rm -f "$ERR_FILE" "$INVENTORY"' EXIT

# Run a listing command and print its JSON on stdout. On failure (API disabled,
# missing permission…) warn and return 1: an unreadable type is reported, never
# silently treated as empty.
list_json() {
  local type_label="$1"; shift
  local out
  if ! out=$("$@" --project "$GCP_PROJECT_ID" --format=json 2>"$ERR_FILE"); then
    echo "  WARNING: could not list ${type_label}: $(tr '\n' ' ' <"$ERR_FILE")" >&2
    return 1
  fi
  printf '%s\n' "${out:-[]}"
}

# Append the app's resources from a listing to the inventory. The jq program
# receives each item already narrowed to {labels, name, location, display}.
record() {
  local type="$1" json="$2" shape="$3"
  jq -r --arg app "$APP_NAME" --arg type "$type" --arg region "$GCP_REGION" "
    .[] | ${shape}
    | select(.labels.application == \$app)
    | [(.labels.environment // \"\"), \$type, .name, (.location // \"\"), (.display // .name)]
    | join(\"\\u001f\")" <<<"$json" >>"$INVENTORY"
}

# Cloud Run labels are patched through the v2 API with updateMask=labels:
# `gcloud run services update --update-labels` also rewrites the revision
# template, which deploys a new revision.
tag_cloud_run_service() {
  local name="$1" location="$2"
  local url="https://run.googleapis.com/v2/projects/${GCP_PROJECT_ID}/locations/${location}/services/${name}"
  local token current merged

  token=$(gcloud auth print-access-token) || return 1
  current=$(curl -sS --fail-with-body -H "Authorization: Bearer ${token}" "$url") || {
    echo "$current" >&2; return 1; }
  merged=$(jq -c --argjson add "$LABELS_JSON" '{labels: ((.labels // {}) + $add)}' <<<"$current") || return 1
  curl -sS --fail-with-body -X PATCH \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    --data "$merged" \
    "${url}?updateMask=labels" >&2 || return 1
}

# Merge the labels onto one inventory entry.
apply_labels() {
  local type="$1" name="$2" location="$3"
  local scope=()
  case "$type" in
    run-service)
      tag_cloud_run_service "$name" "$location" ;;
    artifact-repository)
      gcloud artifacts repositories update "$name" --project "$GCP_PROJECT_ID" \
        --location "$location" --update-labels "$LABELS_ARG" ;;
    certificate|dns-authorization)
      gcloud certificate-manager "${type}s" update "$name" \
        --project "$GCP_PROJECT_ID" --location "$location" --update-labels "$LABELS_ARG" ;;
    address|forwarding-rule)
      local group=addresses
      if [[ "$type" == "forwarding-rule" ]]; then group=forwarding-rules; fi
      if [[ "$location" == "global" ]]; then scope=(--global); else scope=(--region "$location"); fi
      gcloud compute "$group" update "$name" --project "$GCP_PROJECT_ID" \
        "${scope[@]}" --update-labels "$LABELS_ARG" ;;
    dns-zone)
      gcloud dns managed-zones update "$name" --project "$GCP_PROJECT_ID" \
        --update-labels "$LABELS_ARG" ;;
    alert-policy)
      gcloud monitoring policies update "$name" --project "$GCP_PROJECT_ID" \
        --update-user-labels "$LABELS_ARG" ;;
    bucket)
      gcloud storage buckets update "gs://${name}" --project "$GCP_PROJECT_ID" \
        --update-labels "$LABELS_ARG" ;;
    *)
      echo "unsupported type ${type}" >&2; return 1 ;;
  esac
}

# Apply the labels to one inventory entry, or just announce it in dry-run.
tag_resource() {
  local type="$1" name="$2" location="$3" display="$4"
  local label="${type} ${display}${location:+ (${location})}"

  if [[ "$DRYRUN" == "true" ]]; then
    echo "  [dry-run] tag: ${label}"
    return
  fi

  if apply_labels "$type" "$name" "$location" >/dev/null 2>"$ERR_FILE"; then
    echo "  tagged:   ${label}"
    TOTAL_RESOURCES=$((TOTAL_RESOURCES + 1))
  else
    echo "  WARNING: could not tag ${label}: $(tr '\n' ' ' <"$ERR_FILE")" >&2
    TOTAL_FAILED=$((TOTAL_FAILED + 1))
  fi
}

# ── Discover resources ────────────────────────────────────────────────────────
echo
echo "Discovering resources labelled application=${APP_NAME}…"

# Regional listings span every location unless --gcp-region narrows them.
if [[ -n "$GCP_REGION" ]]; then
  RUN_SCOPE=(--region "$GCP_REGION")
  AR_SCOPE=(--location "$GCP_REGION")
  CM_SCOPE=(--location "$GCP_REGION")
else
  RUN_SCOPE=()
  AR_SCOPE=(--location all)
  CM_SCOPE=(--location -)
fi
# Location segment of a `projects/<p>/locations/<loc>/…` resource name.
NAME_SHAPE='{labels, name: (.name | split("/") | last), location: (.name | split("/")[3])}'
# Compute resources: region basename, or "global"; filtered to --gcp-region.
COMPUTE_SHAPE='{labels, name, location: (.region // "global" | split("/") | last)}
  | select($region == "" or .location == "global" or .location == $region)'

if JSON=$(list_json "Cloud Run services" gcloud run services list ${RUN_SCOPE[@]+"${RUN_SCOPE[@]}"}); then
  record run-service "$JSON" '{labels: .metadata.labels, name: .metadata.name,
    location: .metadata.labels["cloud.googleapis.com/location"]}'
fi
if JSON=$(list_json "Artifact Registry repositories" gcloud artifacts repositories list "${AR_SCOPE[@]}"); then
  record artifact-repository "$JSON" "$NAME_SHAPE"
fi
if JSON=$(list_json "Certificate Manager certificates" gcloud certificate-manager certificates list "${CM_SCOPE[@]}"); then
  record certificate "$JSON" "$NAME_SHAPE"
fi
if JSON=$(list_json "Certificate Manager DNS authorizations" gcloud certificate-manager dns-authorizations list "${CM_SCOPE[@]}"); then
  record dns-authorization "$JSON" "$NAME_SHAPE"
fi
if JSON=$(list_json "compute addresses" gcloud compute addresses list); then
  record address "$JSON" "$COMPUTE_SHAPE"
fi
if JSON=$(list_json "compute forwarding rules" gcloud compute forwarding-rules list); then
  record forwarding-rule "$JSON" "$COMPUTE_SHAPE"
fi
if JSON=$(list_json "Cloud DNS managed zones" gcloud dns managed-zones list); then
  record dns-zone "$JSON" '{labels, name}'
fi
if JSON=$(list_json "alert policies" gcloud monitoring policies list); then
  record alert-policy "$JSON" '{labels: .userLabels, name, display: .displayName}'
fi
if JSON=$(list_json "Cloud Storage buckets" gcloud storage buckets list); then
  record bucket "$JSON" '{labels, name}'
fi

ENVS=()
while IFS= read -r ENV; do
  if [[ -n "$ENV" ]]; then ENVS+=("$ENV"); fi
done < <(cut -d $'\037' -f1 "$INVENTORY" | sort -u)

UNGROUPED=$(awk -F'\037' '$1 == ""' "$INVENTORY")
if [[ -n "$UNGROUPED" ]]; then
  echo "WARNING: skipping resources labelled application=${APP_NAME} without an environment label:" >&2
  while IFS=$'\037' read -r _ TYPE _ LOCATION DISPLAY; do
    echo "  ${TYPE} ${DISPLAY}${LOCATION:+ (${LOCATION})}" >&2
  done <<<"$UNGROUPED"
fi

if [[ ${#ENVS[@]} -eq 0 ]]; then
  echo "No resources labelled application=${APP_NAME} with an environment label found in ${GCP_PROJECT_ID}. Nothing to do."
  exit 0
fi

echo "Found ${#ENVS[@]} environment(s):"
printf '  %s\n' "${ENVS[@]}"

if [[ "$DRYRUN" == "true" ]]; then
  echo
  echo "[dry-run mode — no labels will be written]"
fi
echo

# ── Tag each environment's resources ──────────────────────────────────────────
TOTAL_RESOURCES=0
TOTAL_FAILED=0

for ENV in "${ENVS[@]}"; do
  echo "── ${APP_NAME} / ${ENV} $(printf '%.0s─' {1..50})"
  while IFS=$'\037' read -r _ TYPE NAME LOCATION DISPLAY; do
    tag_resource "$TYPE" "$NAME" "$LOCATION" "$DISPLAY"
  done < <(awk -F'\037' -v env="$ENV" '$1 == env' "$INVENTORY")
  echo
done

if [[ "$DRYRUN" == "true" ]]; then
  echo "Dry run complete. No labels were written."
else
  echo "Done. Tagged ${TOTAL_RESOURCES} resource(s) across ${#ENVS[@]} environment(s); ${TOTAL_FAILED} could not be tagged."
fi
