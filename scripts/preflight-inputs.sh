#!/usr/bin/env bash
# preflight-inputs.sh — fail-fast existence checks for the provisioning
# workflows (P15). Confirms, BEFORE anything is created:
#
#   1. the infrastructure template repo exists and is accessible
#   2. its pinned ref (when provided) resolves to a commit
#   3. the application template repo and ref, likewise (when provided)
#   4. the container image manifest exists and is anonymously pullable —
#      the same access mode ECS / App Service uses on first deploy, so a
#      mistyped image fails here with a named error instead of a service
#      waiting forever for an image it can never pull
#
# Every check runs; ALL failures are reported together — one ::error::
# annotation per finding plus a table in the job summary — and the script
# exits non-zero if any check failed.
#
# Inputs via environment:
#   INFRA_TEMPLATE_REPO   owner/name                                (required)
#   INFRA_TEMPLATE_REF    git ref pinning it, or empty
#   APP_TEMPLATE_REPO     owner/name, or empty (infra-only run)
#   APP_TEMPLATE_REF      git ref pinning it, or empty
#   CONTAINER_IMAGE_FULL  full image reference incl. registry host  (required)
#   GH_TOKEN              token for the repo checks — the same one the run
#                         uses later, so success here proves accessibility
#
# Requires: gh, docker (both preinstalled on ubuntu-latest runners).

# Deliberately NOT set -e: every check must run so the report is complete.
set -uo pipefail

RESULTS=()   # "status<TAB>check<TAB>detail" rows for the summary table
FAILED=0

note_ok () { RESULTS+=("✅	$1	$2"); echo "ok:   $1 — $2"; }
note_fail () {
  # Keep the detail single-line and free of '|' so the summary table renders.
  local detail; detail=$(tr '\n' ' ' <<<"$2" | tr '|' '/')
  RESULTS+=("❌	$1	${detail}")
  echo "::error::Preflight: $1 — ${detail}"
  FAILED=1
}

# ── 1+2/3: template repositories and their pinned refs ──────────────────────
check_repo_and_ref () {
  local label="$1" repo="$2" ref="$3" err sha
  if ! err=$(gh api "repos/${repo}" --jq .full_name 2>&1 >/dev/null); then
    if grep -q "HTTP 404" <<<"${err}"; then
      note_fail "${label} repo" "'${repo}' not found, or not accessible with the workflow's token — check the owner/name spelling"
    else
      note_fail "${label} repo" "could not verify '${repo}': ${err}"
    fi
    return   # the ref cannot be checked without the repo
  fi
  note_ok "${label} repo" "'${repo}' exists and is accessible"

  if [[ -n "${ref}" ]]; then
    # commits/<ref> resolves branches, tags and commit SHAs alike.
    if sha=$(gh api "repos/${repo}/commits/${ref}" --jq .sha 2>/dev/null); then
      note_ok "${label} ref" "'${ref}' resolves to ${sha:0:7}"
    else
      note_fail "${label} ref" "'${ref}' does not resolve in '${repo}' — expected an existing tag, branch or commit SHA"
    fi
  fi
}

check_repo_and_ref "infra template" "${INFRA_TEMPLATE_REPO}" "${INFRA_TEMPLATE_REF:-}"

if [[ -n "${APP_TEMPLATE_REPO:-}" ]]; then
  check_repo_and_ref "app template" "${APP_TEMPLATE_REPO}" "${APP_TEMPLATE_REF:-}"
else
  note_ok "app template" "not provided — infra-only run, check skipped"
fi

# ── 4: container image manifest, anonymously ────────────────────────────────
# `docker manifest inspect` queries the registry without pulling layers and
# without credentials — exactly how the infrastructure pulls a public image
# on first deploy. GH_TOKEN is unset for this call so a docker login from an
# earlier step can never mask an image that is not actually public.
# Tooling absence must fail as a tooling error, never as "image not found".
if ! command -v docker >/dev/null; then
  note_fail "container image" "docker CLI not available on this runner — the image check could not run at all (this is a tooling problem, not a verdict on '${CONTAINER_IMAGE_FULL}')"
elif OUT=$(docker manifest inspect "${CONTAINER_IMAGE_FULL}" 2>&1 >/dev/null); then
  note_ok "container image" "'${CONTAINER_IMAGE_FULL}' manifest found — anonymously pullable"
else
  note_fail "container image" "'${CONTAINER_IMAGE_FULL}' manifest not found or not anonymously accessible — the first deploy would wait forever for an image it cannot pull. Registry said: ${OUT}"
fi

# ── Report ───────────────────────────────────────────────────────────────────
{
  echo "## Preflight checks"
  echo ""
  echo "| Result | Check | Detail |"
  echo "|--------|-------|--------|"
  for row in "${RESULTS[@]}"; do
    IFS=$'\t' read -r s c d <<<"${row}"
    echo "| ${s} | ${c} | ${d} |"
  done
  echo ""
  if [[ "${FAILED}" -eq 1 ]]; then
    echo "> One or more inputs failed verification. Nothing was created — fix the values above and re-run."
  fi
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

exit "${FAILED}"
