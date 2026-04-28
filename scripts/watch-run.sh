#!/usr/bin/env bash
# watch-run.sh
# Discover a workflow run on a remote repo by filename or display-name match,
# then wait for it to finish and report its conclusion. Used by the
# provision-infrastructure workflow to observe the CI run it dispatches in
# the application repo and the deploy run that CI is expected to chain into.
#
# Usage:
#   scripts/watch-run.sh \
#     --repo owner/name \
#     --since 2026-04-28T10:00:00Z \
#     --output-key ci \
#     [--workflow ci.yml]                # match by workflow file
#     [--name-pattern '^Deploy$']        # match by run/workflow display-name
#     [--timeout-min 20]
#
# Outputs (appended to $GITHUB_OUTPUT when set):
#   <output-key>_run_id=<id>     (empty if no run was found)
#   <output-key>_run_url=<url>
#   <output-key>_conclusion=<success|failure|cancelled|timed_out|skipped|unknown|not_found>
#
# Exit code: always 0 — the conclusion field signals what happened. Callers
# decide whether to fail based on that.

set -uo pipefail

REPO=""; SINCE=""; OUT_KEY=""
WORKFLOW=""; NAME_PATTERN=""; TIMEOUT_MIN=20

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)         REPO="$2";          shift 2 ;;
    --since)        SINCE="$2";         shift 2 ;;
    --output-key)   OUT_KEY="$2";       shift 2 ;;
    --workflow)     WORKFLOW="$2";      shift 2 ;;
    --name-pattern) NAME_PATTERN="$2";  shift 2 ;;
    --timeout-min)  TIMEOUT_MIN="$2";   shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -z "$REPO"    ]] && { echo "--repo is required"        >&2; exit 2; }
[[ -z "$SINCE"   ]] && { echo "--since is required"       >&2; exit 2; }
[[ -z "$OUT_KEY" ]] && { echo "--output-key is required"  >&2; exit 2; }
[[ -z "$WORKFLOW" && -z "$NAME_PATTERN" ]] && { echo "--workflow or --name-pattern required" >&2; exit 2; }

emit() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "${OUT_KEY}_$1=$2" >> "$GITHUB_OUTPUT"
  fi
  echo "  ${OUT_KEY}_$1=$2"
}

# ── Find the run ──────────────────────────────────────────────────────────────
echo "Looking for run in ${REPO} created since ${SINCE}…"
RUN_ID=""
DEADLINE=$(( $(date +%s) + TIMEOUT_MIN * 60 ))

while [[ $(date +%s) -lt $DEADLINE ]]; do
  if [[ -n "$WORKFLOW" ]]; then
    RUN_ID=$(gh run list -R "$REPO" --workflow "$WORKFLOW" --created ">${SINCE}" \
              --limit 1 --json databaseId --jq '.[0].databaseId // empty' 2>/dev/null || true)
  else
    RUN_ID=$(gh run list -R "$REPO" --created ">${SINCE}" --limit 20 \
              --json databaseId,name,workflowName \
              --jq "map(select((.name // .workflowName) | test(\"${NAME_PATTERN}\"; \"i\"))) | .[0].databaseId // empty" 2>/dev/null || true)
  fi
  [[ -n "$RUN_ID" ]] && break
  sleep 5
done

if [[ -z "$RUN_ID" ]]; then
  echo "::warning::No matching run found within ${TIMEOUT_MIN}m"
  emit run_id      ""
  emit run_url     ""
  emit conclusion  "not_found"
  exit 0
fi

URL="https://github.com/${REPO}/actions/runs/${RUN_ID}"
echo "Found run #${RUN_ID} → ${URL}"
emit run_id  "$RUN_ID"
emit run_url "$URL"

# ── Wait for completion ───────────────────────────────────────────────────────
gh run watch "$RUN_ID" -R "$REPO" --exit-status >/dev/null 2>&1 || true
CONCLUSION=$(gh run view "$RUN_ID" -R "$REPO" --json conclusion --jq '.conclusion // "unknown"')
echo "Conclusion: ${CONCLUSION}"
emit conclusion "$CONCLUSION"
