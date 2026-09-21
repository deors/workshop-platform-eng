#!/usr/bin/env bash
#
# remove-aws-fedcreds.sh — remove GitHub OIDC subjects ("federated
# credentials") from the trust policy of the platform's AWS IAM role.
#
# Usage:
#   ./remove-aws-fedcreds.sh [<account-id>] [<role-name>]
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
#   PLATFORM_REPO   <owner>/<name> of the platform repo (default: the checkout
#                   this script lives in — scripts/local/ of the platform repo)
#
# On AWS there are no per-credential objects: every trusted GitHub subject
# lives inside the role's single trust-policy document, as a value of the
# `token.actions.githubusercontent.com:sub` condition of a statement that
# allows sts:AssumeRoleWithWebIdentity from the GitHub OIDC provider. This
# script lists those subjects and removes the ones you pick by rewriting the
# document (read-modify-write, one UpdateAssumeRolePolicy per command):
#   - a subject list that becomes empty takes its statement with it — a
#     GitHub statement without a subject condition would trust EVERY GitHub
#     repository, so it is never left behind;
#   - when the last statement goes, the document is replaced with a single
#     Deny statement on the account root (no Allow, so no trusted
#     principals), because a role cannot exist without a trust policy.
#     setup-aws-fedcreds.sh rebuilds it from scratch.
# Statements that are not GitHub-OIDC, and GitHub statements with no subject
# condition at all, are KEPT and reported, never edited.
#
# Safety:
#   - Always lists the exact subjects found, numbered. Nothing is removed
#     without typing an explicit command: 'DELETE SUBJECT <number>' removes
#     one at a time (the prompt loops so several can be removed),
#     'DELETE ALL SUBJECTS' removes every remaining one, and anything else
#     exits.
#   - The confirmation is read from /dev/tty, so it cannot be bypassed by
#     piping input, redirecting stdin, or running non-interactively.
#   - There is deliberately no --yes/--force option.
#
# Requires: `aws` logged in (iam:GetRole + iam:UpdateAssumeRolePolicy on the
# role) and `jq`.

set -euo pipefail

if [ ! -e /dev/tty ]; then
  echo "error: no terminal available — this script only runs interactively." >&2
  exit 1
fi

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

SUB_KEY="token.actions.githubusercontent.com:sub"

if ! CALLER=$(aws sts get-caller-identity --query Account --output text 2>/dev/null); then
  echo "error: the AWS CLI is not logged in (aws sts get-caller-identity failed)" >&2
  exit 1
fi
if [ "${CALLER}" != "${ACCOUNT_ID}" ]; then
  echo "error: the AWS CLI is logged into account ${CALLER}, not ${ACCOUNT_ID} — refusing to continue" >&2
  exit 1
fi

echo "AWS account: ${ACCOUNT_ID}"
echo "IAM role:    ${ROLE_NAME}"

if ! TRUST=$(aws iam get-role --role-name "${ROLE_NAME}" \
               --query Role.AssumeRolePolicyDocument --output json 2>/dev/null); then
  echo "error: role ${ROLE_NAME} not found in account ${ACCOUNT_ID} (or no iam:GetRole permission)" >&2
  exit 1
fi

# jq predicate: is this statement the GitHub-OIDC federation statement?
IS_GH='(.Effect == "Allow")
       and ([.Action] | flatten | any(. == "sts:AssumeRoleWithWebIdentity"))
       and ([.Principal.Federated? // empty] | flatten
            | any(tostring | test("oidc-provider/token\\.actions\\.githubusercontent\\.com$")))'

echo "Scanning trust policy..."
echo

# One line per subject: <statement-index>\t<operator>\t<subject>
SUBJECT_ROWS=$(jq -r --arg sub "${SUB_KEY}" "
  .Statement | to_entries[]
  | select(.value | ${IS_GH})
  | .key as \$i
  | (.value.Condition // {}) | to_entries[]
  | select(.key | test(\"^String(Equals|Like)\$\"))
  | .key as \$op
  | .value[\$sub]? // empty
  | (if type == \"array\" then .[] else . end)
  | [\$i, \$op, .] | @tsv" <<<"${TRUST}")

# Report what is deliberately out of scope.
jq -r --arg sub "${SUB_KEY}" "
  .Statement | to_entries[]
  | if (.value | ${IS_GH}) then
      if ([(.value.Condition // {})[]? | .[\$sub]? // empty] | length) == 0 then
        \"keep:  statement #\\(.key) is GitHub-OIDC but has NO subject condition (trusts the whole issuer) — review manually\"
      else empty end
    else
      \"keep:  statement #\\(.key) is not GitHub-OIDC (\\(.value.Effect) \\([.value.Action] | flatten | join(\",\")) for \\(.value.Principal | tostring)) — out of scope\"
    end" <<<"${TRUST}"

STMT_IDX=()
STMT_OP=()
SUBJECTS=()
while IFS=$'\t' read -r I OP SUBJECT; do
  [ -z "${SUBJECT}" ] && continue
  STMT_IDX+=("${I}")
  STMT_OP+=("${OP}")
  SUBJECTS+=("${SUBJECT}")
done <<<"${SUBJECT_ROWS}"

COUNT="${#SUBJECTS[@]}"
if [ "${COUNT}" -eq 0 ]; then
  echo
  echo "Nothing to delete — the trust policy of ${ROLE_NAME} has no GitHub OIDC subjects."
  exit 0
fi

echo
echo "The following ${COUNT} GitHub OIDC subject$([ "${COUNT}" -eq 1 ] && echo '' || echo s) can be PERMANENTLY removed from the trust policy of ${ROLE_NAME}:"
echo
I=0
while [ "${I}" -lt "${COUNT}" ]; do
  echo "  [$((I + 1))] ${SUBJECTS[$I]}  (${STMT_OP[$I]}, statement #${STMT_IDX[$I]})"
  I=$((I + 1))
done
echo
echo "Removals cannot be undone. Workflows presenting a removed subject fail at"
echo "sts:AssumeRoleWithWebIdentity until setup-aws-fedcreds.sh restores it."
echo "If every subject is removed, the trust policy becomes a Deny-only document."

DELETED=()
for S in "${SUBJECTS[@]}"; do DELETED+=("no"); done

# Trust policy left when nothing trusted remains. IAM rejects a bare "*"
# principal in trust policies and only accepts sts:AssumeRole* actions, so
# the Deny names the account root and the three assume-role actions;
# with no Allow statement at all, nobody can assume the role either way.
NO_TRUST=$(jq -nc --arg root "arn:aws:iam::${ACCOUNT_ID}:root" \
  '{Version: "2012-10-17", Statement: [{Sid: "NoTrustedPrincipals", Effect: "Deny", Principal: {AWS: $root}, Action: ["sts:AssumeRole", "sts:AssumeRoleWithWebIdentity", "sts:AssumeRoleWithSAML"]}]}')

# Rewrite the ORIGINAL document without every subject marked deleted (plus the
# ones in the pending list) and push it. Deriving from the original each time
# keeps the write idempotent across retries.
write_trust() {
  local RM='[]' I=0
  while [ "${I}" -lt "${COUNT}" ]; do
    if [ "${DELETED[$I]}" = "yes" ] || [ "${DELETED[$I]}" = "pending" ]; then
      RM=$(jq -c --argjson i "${STMT_IDX[$I]}" --arg op "${STMT_OP[$I]}" --arg s "${SUBJECTS[$I]}" \
             '. + [{i: $i, op: $op, sub: $s}]' <<<"${RM}")
    fi
    I=$((I + 1))
  done

  local NEW_DOC
  NEW_DOC=$(jq -c --arg sub "${SUB_KEY}" --argjson rm "${RM}" --argjson empty "${NO_TRUST}" "
    .Statement |= [ to_entries[] | .key as \$i | .value
      | if (${IS_GH}) and (([\$rm[] | select(.i == \$i)] | length) > 0) then
          # strip the targeted subjects from each condition operator
          .Condition |= with_entries(.key as \$op
            | if (.key | test(\"^String(Equals|Like)\$\")) and (.value | has(\$sub)) then
                .value[\$sub] |= ((if type == \"array\" then . else [.] end)
                  | map(. as \$s | select(([\$rm[] | select(.i == \$i and .op == \$op and .sub == \$s)] | length) == 0)))
              else . end)
          # an emptied subject list disappears with its key
          | .Condition |= with_entries(
              if (.value | type) == \"object\" and (.value | has(\$sub)) and ((.value[\$sub] | length) == 0)
              then .value |= del(.[\$sub]) else . end)
          # a GitHub statement must keep at least one subject or go away entirely
          | select(([.Condition[]? | .[\$sub]? // empty] | length) > 0)
        else . end ]
    | if (.Statement | length) == 0 then \$empty else . end" <<<"${TRUST}")

  aws iam update-assume-role-policy --role-name "${ROLE_NAME}" --policy-document "${NEW_DOC}"
}

# Mark the given 0-based indexes pending, write once, then settle them.
delete_many() {
  local IDX
  for IDX in "$@"; do DELETED[$IDX]="pending"; done
  if write_trust; then
    for IDX in "$@"; do
      DELETED[$IDX]="yes"
      echo "removed: [$((IDX + 1))] ${SUBJECTS[$IDX]}"
    done
    return 0
  fi
  for IDX in "$@"; do
    DELETED[$IDX]="no"
    echo "error: failed to remove [$((IDX + 1))] ${SUBJECTS[$IDX]} — trust policy left unchanged" >&2
  done
  return 1
}

remaining() {
  local N=0 S
  for S in "${DELETED[@]}"; do [ "$S" = "no" ] && N=$((N + 1)); done
  echo "$N"
}

FAILED=0
while :; do
  LEFT=$(remaining)
  if [ "${LEFT}" -eq 0 ]; then
    echo "All GitHub OIDC subjects removed from the trust policy of ${ROLE_NAME}."
    break
  fi
  echo
  printf "Type 'DELETE SUBJECT <number>' to remove one, 'DELETE ALL SUBJECTS' to remove the %s remaining, anything else exits: " "${LEFT}"
  read -r REPLY < /dev/tty

  if [ "${REPLY}" = "DELETE ALL SUBJECTS" ]; then
    PENDING=()
    I=0
    while [ "${I}" -lt "${COUNT}" ]; do
      [ "${DELETED[$I]}" = "no" ] && PENDING+=("${I}")
      I=$((I + 1))
    done
    delete_many "${PENDING[@]}" || FAILED=1
  elif [[ "${REPLY}" =~ ^DELETE\ SUBJECT\ ([0-9]+)$ ]]; then
    N="${BASH_REMATCH[1]}"
    if [ "$N" -lt 1 ] || [ "$N" -gt "${COUNT}" ]; then
      echo "No subject [${N}] — valid numbers are 1..${COUNT}."
    elif [ "${DELETED[$((N - 1))]}" = "yes" ]; then
      echo "Subject [${N}] was already removed."
    else
      delete_many "$((N - 1))" || FAILED=1
    fi
  else
    echo "Exiting — $((COUNT - LEFT)) removed, ${LEFT} remaining."
    break
  fi
done

exit "${FAILED}"
