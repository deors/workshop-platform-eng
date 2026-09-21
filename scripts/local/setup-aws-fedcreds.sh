#!/usr/bin/env bash
#
# setup-aws-fedcreds.sh — configure, from scratch, the AWS side of the
# platform's GitHub OIDC federation: identity provider, IAM role with its
# trust policy (the "federated credentials"), the three customer-managed
# permission policies and the self-manage-trust inline policy.
#
# Usage:
#   ./setup-aws-fedcreds.sh [<account-id>] [<role-name>]
#
# Both identifiers resolve the same way, in this order — the first non-empty
# value wins (the same precedence the workflows use):
#   account : argument 1 → AWS_ACCOUNT_ID → account of PROVISION_AWS_ROLE_ARN (repo variable)
#   role    : argument 2 → AWS_ROLE_NAME  → role of PROVISION_AWS_ROLE_ARN → GitHubActionsPlatformEng
# The script refuses to run unless the AWS CLI is currently logged into
# exactly the resolved account — the CLI cannot switch accounts on its own,
# so this is a guard against operating on the wrong one.
#
# Optional environment:
#   PLATFORM_REPO   <owner>/<name> of the platform repo whose workflows assume
#                   the role (default: the checkout this script lives in —
#                   scripts/local/ of the platform repo — via `gh repo view`)
#   SUBJECT_PREFIX  OIDC subject prefix the repo presents (default: queried
#                   from GitHub — `repo:<owner>/<name>`, or the immutable-ID
#                   form `repo:<owner>@<id>/<name>@<id>` for repos created
#                   after 2026-07-15). Never guessed: a wrong prefix fails
#                   silently at sts:AssumeRoleWithWebIdentity later.
#   POLICY_DIR      directory with the three policy JSON files (default:
#                   setup/aws-policies of the same checkout; `<account-id>`
#                   placeholders are substituted)
#
# Every step is idempotent — the script converges the account on the desired
# state and reports per item whether it was created, updated or already OK:
#   1. GitHub OIDC identity provider (token.actions.githubusercontent.com)
#   2. IAM role with a trust policy holding exactly the platform's four
#      subjects: <prefix>:ref:refs/heads/main and <prefix>:environment:{dev,
#      staging,prod}. An existing trust policy is REPLACED wholesale; if it
#      holds subjects beyond those four (app repos registered by the
#      provisioning workflow), they are listed and the replacement needs an
#      explicit typed confirmation — re-provisioning those apps restores them.
#   3. Managed policies PlatformEngInfraServices, PlatformEngTerraformState,
#      PlatformEngScopedIAM — created when missing; when the document differs
#      from the file, a new default version is published (the oldest
#      non-default version is pruned first if the 5-version cap is reached)
#   4. The three policies attached to the role
#   5. Inline policy `self-manage-trust-policy` (iam:GetRole +
#      iam:UpdateAssumeRolePolicy on the role itself), so the provisioning
#      workflow can append app-repo subjects
#
# Requires: `aws` logged in with IAM write access, `gh` authenticated (repo
# admin, to read the OIDC subject prefix), and `jq`.

set -euo pipefail

for TOOL in aws gh jq; do
  command -v "$TOOL" >/dev/null || { echo "error: $TOOL not installed" >&2; exit 1; }
done

# This script lives in scripts/local/ of the platform repo checkout.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PLATFORM_REPO="${PLATFORM_REPO:-$(cd "${REPO_ROOT}" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)}"
if [ -z "${PLATFORM_REPO}" ]; then
  echo "error: could not resolve the platform repo — set PLATFORM_REPO=<owner>/<name>" >&2
  exit 1
fi

# Prints the repo variable's value, or nothing when unset.
repo_var() { gh variable get "$1" -R "${PLATFORM_REPO}" 2>/dev/null || true; }
VAR_ROLE_ARN="$(repo_var PROVISION_AWS_ROLE_ARN)"   # arn:aws:iam::<account>:role/<name>

# ── Identifiers: argument → environment → repo variable ─────────────────────

ACCOUNT_ID="${1:-${AWS_ACCOUNT_ID:-$(cut -d: -f5 <<<"${VAR_ROLE_ARN}")}}"
if [ -z "${ACCOUNT_ID}" ]; then
  echo "error: no account ID — pass it as argument 1, set AWS_ACCOUNT_ID, or set the PROVISION_AWS_ROLE_ARN repo variable" >&2
  exit 2
fi
if ! [[ "${ACCOUNT_ID}" =~ ^[0-9]{12}$ ]]; then
  echo "error: '${ACCOUNT_ID}' is not a 12-digit AWS account ID" >&2
  exit 2
fi

ROLE_NAME="${2:-${AWS_ROLE_NAME:-${VAR_ROLE_ARN##*/}}}"
ROLE_NAME="${ROLE_NAME:-GitHubActionsPlatformEng}"
if ! [[ "${ROLE_NAME}" =~ ^[A-Za-z0-9+=,.@_-]{1,64}$ ]]; then
  echo "error: '${ROLE_NAME}' is not a valid IAM role name" >&2
  exit 2
fi

ROLE_DESCRIPTION="OIDC role assumed by the platform-eng GitHub Actions workflows"
POLICY_DIR="${POLICY_DIR:-${REPO_ROOT}/setup/aws-policies}"
OIDC_HOST="token.actions.githubusercontent.com"
OIDC_PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_HOST}"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
SUB_KEY="${OIDC_HOST}:sub"
INLINE_POLICY_NAME="self-manage-trust-policy"

# file-stem:PolicyName — file lives in POLICY_DIR as <stem>.json
POLICIES="platform-eng-infra-services:PlatformEngInfraServices
platform-eng-terraform-state:PlatformEngTerraformState
platform-eng-scoped-iam:PlatformEngScopedIAM"

# ── Guards ───────────────────────────────────────────────────────────────────
if ! CALLER=$(aws sts get-caller-identity --query Account --output text 2>/dev/null); then
  echo "error: the AWS CLI is not logged in (aws sts get-caller-identity failed)" >&2
  exit 1
fi
if [ "${CALLER}" != "${ACCOUNT_ID}" ]; then
  echo "error: the AWS CLI is logged into account ${CALLER}, not ${ACCOUNT_ID} — refusing to continue" >&2
  exit 1
fi

for P in ${POLICIES}; do
  F="${POLICY_DIR}/${P%%:*}.json"
  [ -f "${F}" ] || { echo "error: policy file not found: ${F} (set POLICY_DIR)" >&2; exit 1; }
done

# ── Resolve the OIDC subject prefix ──────────────────────────────────────────
if [ -z "${SUBJECT_PREFIX:-}" ]; then
  SUBJECT_PREFIX=$(gh api "repos/${PLATFORM_REPO}/actions/oidc/customization/sub" \
                     --jq '.sub_claim_prefix // empty' 2>/dev/null || true)
  if [ -z "${SUBJECT_PREFIX}" ]; then
    echo "error: could not read the OIDC subject prefix of ${PLATFORM_REPO} (needs repo admin) — set SUBJECT_PREFIX explicitly" >&2
    exit 1
  fi
fi

echo "AWS account:    ${ACCOUNT_ID}"
echo "IAM role:       ${ROLE_NAME}"
echo "Platform repo:  ${PLATFORM_REPO}"
echo "Subject prefix: ${SUBJECT_PREFIX}"
echo "Policy files:   ${POLICY_DIR}"
echo

DESIRED_SUBJECTS=$(jq -nc --arg p "${SUBJECT_PREFIX}" \
  '[$p + ":ref:refs/heads/main", $p + ":environment:dev", $p + ":environment:staging", $p + ":environment:prod"] | sort')

DESIRED_TRUST=$(jq -nc --arg prov "${OIDC_PROVIDER_ARN}" --arg sub "${SUB_KEY}" --arg aud "${OIDC_HOST}:aud" \
                   --argjson subs "${DESIRED_SUBJECTS}" '{
  Version: "2012-10-17",
  Statement: [{
    Effect: "Allow",
    Principal: {Federated: $prov},
    Action: "sts:AssumeRoleWithWebIdentity",
    Condition: {StringEquals: ({($aud): "sts.amazonaws.com"} + {($sub): $subs})}
  }]}')

# ── 1. OIDC identity provider ────────────────────────────────────────────────
echo "[1/5] GitHub OIDC identity provider"
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "${OIDC_PROVIDER_ARN}" >/dev/null 2>&1; then
  echo "ok:      ${OIDC_PROVIDER_ARN} already registered"
else
  # The thumbprint is required by the API but informational for this issuer:
  # AWS validates GitHub's endpoint against its trusted root CAs.
  aws iam create-open-id-connect-provider \
    --url "https://${OIDC_HOST}" \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 >/dev/null
  echo "created: ${OIDC_PROVIDER_ARN}"
fi

# ── 2. Role + trust policy ───────────────────────────────────────────────────
echo
echo "[2/5] IAM role and trust policy"
# Normalise a trust document for comparison: sort subject arrays and keys.
normalise() {
  jq -S --arg sub "${SUB_KEY}" '
    .Statement |= map(
      if (.Condition? | type) == "object" then
        .Condition |= with_entries(
          if (.value | type) == "object" and (.value | has($sub)) then
            .value[$sub] |= ((if type == "array" then . else [.] end) | sort)
          else . end)
      else . end)'
}

if CURRENT_TRUST=$(aws iam get-role --role-name "${ROLE_NAME}" \
                     --query Role.AssumeRolePolicyDocument --output json 2>/dev/null); then
  if [ "$(normalise <<<"${CURRENT_TRUST}")" = "$(normalise <<<"${DESIRED_TRUST}")" ]; then
    echo "ok:      role ${ROLE_NAME} exists, trust policy already holds exactly the four platform subjects"
  else
    # Subjects present now that the desired document would drop.
    EXTRA=$(jq -r --arg sub "${SUB_KEY}" --argjson want "${DESIRED_SUBJECTS}" '
      [.Statement[] | .Condition? // {} | .[]? | .[$sub]? // empty | (if type == "array" then .[] else . end)]
      | unique | map(select(. as $s | ($want | index($s)) == null)) | .[]' <<<"${CURRENT_TRUST}")
    if [ -n "${EXTRA}" ]; then
      echo "The current trust policy of ${ROLE_NAME} holds subjects that are NOT part of the platform baseline:"
      echo
      while IFS= read -r S; do echo "  - ${S}"; done <<<"${EXTRA}"
      echo
      echo "Replacing the trust policy drops them: workflows in those repos fail at"
      echo "sts:AssumeRoleWithWebIdentity until the apps are provisioned again."
      if [ ! -e /dev/tty ]; then
        echo "error: no terminal available to confirm — remove the extra subjects first (remove-aws-fedcreds.sh) or run interactively" >&2
        exit 1
      fi
      printf "Type 'REPLACE TRUST POLICY' to continue, anything else exits: "
      read -r REPLY < /dev/tty
      if [ "${REPLY}" != "REPLACE TRUST POLICY" ]; then
        echo "Exiting — trust policy left unchanged."
        exit 1
      fi
    fi
    aws iam update-assume-role-policy --role-name "${ROLE_NAME}" --policy-document "${DESIRED_TRUST}"
    echo "updated: trust policy of ${ROLE_NAME} replaced with the four platform subjects"
  fi
else
  aws iam create-role \
    --role-name "${ROLE_NAME}" \
    --description "${ROLE_DESCRIPTION}" \
    --assume-role-policy-document "${DESIRED_TRUST}" >/dev/null
  echo "created: role ${ROLE_NAME} with the four platform subjects"
fi

# ── 3. Managed policies ──────────────────────────────────────────────────────
echo
echo "[3/5] Customer-managed policies"
POLICY_ARNS=""
for P in ${POLICIES}; do
  STEM="${P%%:*}"; NAME="${P##*:}"
  ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${NAME}"
  POLICY_ARNS="${POLICY_ARNS} ${ARN}"
  DOC=$(sed "s/<account-id>/${ACCOUNT_ID}/g" "${POLICY_DIR}/${STEM}.json" | jq -c .)

  if ! DEFAULT_VERSION=$(aws iam get-policy --policy-arn "${ARN}" --query Policy.DefaultVersionId --output text 2>/dev/null); then
    aws iam create-policy --policy-name "${NAME}" --policy-document "${DOC}" >/dev/null
    echo "created: policy ${NAME} (v1)"
    continue
  fi

  LIVE=$(aws iam get-policy-version --policy-arn "${ARN}" --version-id "${DEFAULT_VERSION}" \
           --query PolicyVersion.Document --output json | jq -S .)
  if [ "${LIVE}" = "$(jq -S . <<<"${DOC}")" ]; then
    echo "ok:      policy ${NAME} ${DEFAULT_VERSION} matches ${STEM}.json"
    continue
  fi

  # IAM keeps at most 5 versions per policy: prune the oldest non-default one.
  VERSIONS=$(aws iam list-policy-versions --policy-arn "${ARN}" --output json)
  if [ "$(jq '.Versions | length' <<<"${VERSIONS}")" -ge 5 ]; then
    OLDEST=$(jq -r '[.Versions[] | select(.IsDefaultVersion | not)] | sort_by(.CreateDate) | .[0].VersionId' <<<"${VERSIONS}")
    aws iam delete-policy-version --policy-arn "${ARN}" --version-id "${OLDEST}"
    echo "pruned:  policy ${NAME} ${OLDEST} (version cap)"
  fi
  NEW_VERSION=$(aws iam create-policy-version --policy-arn "${ARN}" --policy-document "${DOC}" \
                  --set-as-default --query PolicyVersion.VersionId --output text)
  echo "updated: policy ${NAME} ${DEFAULT_VERSION} → ${NEW_VERSION} (now matches ${STEM}.json)"
done

# ── 4. Attachments ───────────────────────────────────────────────────────────
echo
echo "[4/5] Policy attachments"
ATTACHED=$(aws iam list-attached-role-policies --role-name "${ROLE_NAME}" \
             --query "AttachedPolicies[].PolicyArn" --output text | tr '\t' '\n')
for ARN in ${POLICY_ARNS}; do
  if grep -qxF "${ARN}" <<<"${ATTACHED}"; then
    echo "ok:      ${ARN##*/} already attached"
  else
    aws iam attach-role-policy --role-name "${ROLE_NAME}" --policy-arn "${ARN}"
    echo "attached: ${ARN##*/}"
  fi
done
while IFS= read -r ARN; do
  [ -z "${ARN}" ] && continue
  case " ${POLICY_ARNS} " in *" ${ARN} "*) ;; *)
    echo "note:    ${ARN} is also attached and is not part of the baseline — left as is" ;;
  esac
done <<<"${ATTACHED}"

# ── 5. Inline self-manage-trust policy ───────────────────────────────────────
echo
echo "[5/5] Inline policy ${INLINE_POLICY_NAME}"
INLINE_DOC=$(jq -nc --arg role "${ROLE_ARN}" '{
  Version: "2012-10-17",
  Statement: [{Effect: "Allow", Action: ["iam:GetRole", "iam:UpdateAssumeRolePolicy"], Resource: $role}]}')
if CURRENT_INLINE=$(aws iam get-role-policy --role-name "${ROLE_NAME}" --policy-name "${INLINE_POLICY_NAME}" \
                      --query PolicyDocument --output json 2>/dev/null) \
   && [ "$(jq -S . <<<"${CURRENT_INLINE}")" = "$(jq -S . <<<"${INLINE_DOC}")" ]; then
  echo "ok:      ${INLINE_POLICY_NAME} already in place"
else
  aws iam put-role-policy --role-name "${ROLE_NAME}" --policy-name "${INLINE_POLICY_NAME}" --policy-document "${INLINE_DOC}"
  echo "updated: ${INLINE_POLICY_NAME} written"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo
echo "Done. Role ARN: ${ROLE_ARN}"
echo "Trusted subjects:"
jq -r '.[] | "  - " + .' <<<"${DESIRED_SUBJECTS}"
echo
echo "Point the platform at it (repository variables):"
echo "  gh variable set PROVISION_AWS_ROLE_ARN -R ${PLATFORM_REPO} --body \"${ROLE_ARN}\""
echo "  gh variable set DRIFT_AWS_ROLE_ARN     -R ${PLATFORM_REPO} --body \"${ROLE_ARN}\""
