#!/usr/bin/env bash
# bootstrap-tfstate-aws.sh
# Creates (idempotently) the S3 bucket used as Terraform remote state backend.
# One bucket per AWS account + application; one key per environment inside it.
#
# This script is owned by the PLATFORM, not by any application template.
# Provisioning the state backend is a cross-cutting concern: every template must
# create state the same way, so templates must not carry their own copy. The
# tags and the resource-group query written here are consumed by
# scripts/tag-app-resources-aws.sh and by the drift/verify workflows — keep them
# in sync when changing either side.
#
# Usage:
#   bootstrap-tfstate-aws.sh --app-name <name> --aws-region <region> \
#                            [--aws-account-id <id>]
#
# --app-name and --aws-region are both required; there is no default region.
#
# Outputs (stdout, last lines):
#   TFSTATE_BUCKET=tf-state-<app>-<account8>
#   TFSTATE_REGION=<region>

set -euo pipefail

log()  { echo "[bootstrap-tfstate-aws] $*" >&2; }
err()  { echo "[bootstrap-tfstate-aws] ERROR: $*" >&2; exit 1; }
ok()   { echo "[bootstrap-tfstate-aws] ✓ $*" >&2; }
skip() { echo "[bootstrap-tfstate-aws] → $*" >&2; }

APP_NAME=""
AWS_REGION=""
AWS_ACCOUNT_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-name)       APP_NAME="$2";       shift 2 ;;
    --aws-region)     AWS_REGION="$2";     shift 2 ;;
    --aws-account-id) AWS_ACCOUNT_ID="$2"; shift 2 ;;
    *) err "Unknown argument: $1" ;;
  esac
done

[[ -z "$APP_NAME"   ]] && err "--app-name is required"
# No default region: the bucket is created in whatever region is passed, and a
# silently-defaulted one puts the state backend somewhere nobody expects.
[[ -z "$AWS_REGION" ]] && err "--aws-region is required"

command -v aws &>/dev/null || err "AWS CLI not found. Install from https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
command -v jq  &>/dev/null || err "jq not found. Install with: brew install jq"

if [[ -z "$AWS_ACCOUNT_ID" ]]; then
  AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  log "Resolved AWS account ID: $AWS_ACCOUNT_ID"
fi

# Bucket name: tf-state-<app>-<first 8 chars of account>
# S3 bucket names: 3-63 chars, lowercase alphanumeric and hyphens, globally unique
APP_SHORT=$(echo "$APP_NAME" | tr '[:upper:]' '[:lower:]' | tr -d '_' | cut -c1-20)
ACCT_SHORT=$(echo "$AWS_ACCOUNT_ID" | cut -c1-8)
BUCKET_NAME="tf-state-${APP_SHORT}-${ACCT_SHORT}"

log "App name      : $APP_NAME"
log "AWS region    : $AWS_REGION"
log "AWS account   : $AWS_ACCOUNT_ID"
log "State bucket  : $BUCKET_NAME"

# ── S3 Bucket ─────────────────────────────────────────────────────────────────

log "Checking S3 bucket '$BUCKET_NAME'…"
if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
  skip "Bucket already exists"
else
  log "Creating bucket…"
  if [[ "$AWS_REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION"
  else
    aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION" \
      --create-bucket-configuration LocationConstraint="$AWS_REGION"
  fi
  ok "Bucket created"
fi

log "Enforcing bucket security settings…"

aws s3api put-bucket-versioning --bucket "$BUCKET_NAME" \
  --versioning-configuration Status=Enabled
ok "Versioning enabled"

aws s3api put-bucket-encryption --bucket "$BUCKET_NAME" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"},
      "BucketKeyEnabled": true
    }]
  }'
ok "AES-256 encryption enabled"

aws s3api put-public-access-block --bucket "$BUCKET_NAME" \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
ok "Public access blocked"

# ── Transport security ────────────────────────────────────────────────────────
# put-bucket-encryption above protects data AT REST only. The S3 REST endpoint
# still answers plain HTTP, so without this policy state files can be read and
# written unencrypted IN TRANSIT — the "S3 data in transit unencrypted" finding.
# There is no bucket flag for this: it can only be enforced with a policy.
#
# The TLS floor is 1.3, matching the ALB listener policy the application stack
# uses (ELBSecurityPolicy-TLS13-*) so the state backend is held to the same bar
# as the workloads. S3 negotiates TLS 1.3, and both the AWS CLI and the Go TLS
# stack behind Terraform/OpenTofu do too.
#
# The Azure bootstrap deliberately stays at TLS1_2 — this is NOT an oversight:
# Azure Storage does not support a 1.3 floor ("TLS1_3 is not yet supported.
# Microsoft recommends setting MinimumTlsVersion to TLS1_2"). Raise it there
# once Azure supports it.
#
# Both ARNs are listed on purpose. The bucket ARN covers bucket-level calls
# (ListBucket, GetBucketVersioning); the `/*` ARN covers object calls. A policy
# carrying only `/*` leaves bucket-level operations reachable over plain HTTP
# and is still reported by scanners.
#
# `Principal: "*"` with `Effect: Deny` does not conflict with the public-access
# block above: only Allow statements count as granting public access, so
# BlockPublicPolicy accepts this.
BUCKET_POLICY=$(jq -cn \
  --arg bucket "arn:aws:s3:::${BUCKET_NAME}" \
  --arg objects "arn:aws:s3:::${BUCKET_NAME}/*" \
  '{Version: "2012-10-17",
    Statement: [
      {Sid: "DenyUnencryptedTransport",
       Effect: "Deny",
       Principal: "*",
       Action: "s3:*",
       Resource: [$bucket, $objects],
       Condition: {Bool: {"aws:SecureTransport": "false"}}},
      {Sid: "DenyOutdatedTlsVersions",
       Effect: "Deny",
       Principal: "*",
       Action: "s3:*",
       Resource: [$bucket, $objects],
       Condition: {NumericLessThan: {"s3:TlsVersion": "1.3"}}}
    ]}')

aws s3api put-bucket-policy --bucket "$BUCKET_NAME" --policy "$BUCKET_POLICY"
ok "HTTPS-only enforced (TLS 1.3 minimum)"

# put-bucket-tagging REPLACES the whole TagSet — S3 has no merge API for bucket
# tags. Writing the three bootstrap tags directly would therefore delete any tag
# applied later by scripts/tag-app-resources-aws.sh (airid, CreatedBy, cost
# centre…), and this script is meant to be safe to re-run at any time. So read
# what is there, merge, and write the union back.
#
# The bootstrap's own three keys win on conflict: it owns them. Everything else
# is preserved untouched. Note that S3 tag keys are case-sensitive, so a
# `platform` from here and an `Application` from the tagging script are distinct
# keys and both survive.
EXISTING_TAGS='[]'
if EXISTING_JSON=$(aws s3api get-bucket-tagging --bucket "$BUCKET_NAME" --output json 2>&1); then
  EXISTING_TAGS=$(jq -c '.TagSet // []' <<<"$EXISTING_JSON")
elif grep -q "NoSuchTagSet" <<<"$EXISTING_JSON"; then
  EXISTING_TAGS='[]'          # bucket has never been tagged — normal on creation
else
  err "Could not read existing bucket tags: $EXISTING_JSON"
fi

TAGGING=$(jq -cn --argjson existing "$EXISTING_TAGS" --arg app "$APP_NAME" '
  {TagSet: (
    ($existing | map({(.Key): .Value}) | add // {})
    + {"managed-by":  "bootstrap-tfstate",
       "platform":    "platform-engineering",
       "application": $app}
    | to_entries | map({Key: .key, Value: .value})
  )}')

aws s3api put-bucket-tagging --bucket "$BUCKET_NAME" --tagging "$TAGGING"
ok "Tags applied ($(jq '.TagSet | length' <<<"$TAGGING") keys, existing tags preserved)"

# ── Resource Group ────────────────────────────────────────────────────────────
# Groups the state bucket under rg-<app>-tfstate. Kept separate from the
# per-environment rg-<app>-<env> groups that Terraform creates: one bucket
# serves every environment (one state key each), so it carries no environment
# tag and cannot belong to any single environment group. It is also created
# before Terraform runs — it *is* the backend — so Terraform cannot own it.
# Uses APP_NAME verbatim (not the S3-sanitised APP_SHORT) to stay consistent
# with the rg-<app_name>-<env> groups Terraform creates.
RG_NAME="rg-${APP_NAME}-tfstate"

log "Checking resource group '$RG_NAME'…"
if aws resource-groups get-group --region "$AWS_REGION" --group-name "$RG_NAME" &>/dev/null; then
  skip "Resource group already exists"
else
  log "Creating resource group…"
  # The API nests the tag query as a JSON *string* inside the request; build it
  # with jq in two steps so the inner quoting is escaped correctly.
  RG_QUERY_INNER=$(jq -cn --arg app "$APP_NAME" \
    '{ResourceTypeFilters: ["AWS::AllSupported"],
      TagFilters: [
        {Key: "application", Values: [$app]},
        {Key: "managed-by",  Values: ["bootstrap-tfstate"]}
      ]}')
  RG_QUERY=$(jq -cn --arg q "$RG_QUERY_INNER" '{Type: "TAG_FILTERS_1_0", Query: $q}')

  aws resource-groups create-group \
    --region "$AWS_REGION" \
    --name "$RG_NAME" \
    --description "Terraform state backend resources for ${APP_NAME} - shared by all environments" \
    --resource-query "$RG_QUERY" \
    --tags "managed-by=bootstrap-tfstate,platform=platform-engineering,application=${APP_NAME}" \
    >/dev/null
  ok "Resource group created"
fi

# ── Output ────────────────────────────────────────────────────────────────────
echo ""
echo "TFSTATE_BUCKET=${BUCKET_NAME}"
echo "TFSTATE_REGION=${AWS_REGION}"
echo ""
log "Bootstrap complete. Run terraform init with:"
log "  -backend-config=\"bucket=${BUCKET_NAME}\""
log "  -backend-config=\"key=<environment>/terraform.tfstate\""
log "  -backend-config=\"region=${AWS_REGION}\""
