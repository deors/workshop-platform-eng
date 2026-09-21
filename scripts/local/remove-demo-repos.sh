#!/usr/bin/env bash
#
# remove-demo-repos.sh — delete stale demo repositories from the platform's
# GitHub owner (user or organization), plus the GHCR container packages they
# left behind.
#
# Usage:
#   ./remove-demo-repos.sh <base-name> [<base-name> ...]
#
# For each <base-name>, targets the repo with that exact name plus any repo
# named <base-name>-* (e.g. `myapp` targets both `myapp` and `myapp-infra`).
#
# The owner resolves the same way the other local scripts resolve their
# identifiers — the first non-empty value wins:
#   owner : GITHUB_OWNER → owner of the platform repo (the checkout this
#           script lives in — scripts/local/ of the platform repo — via
#           `gh repo view`; override with PLATFORM_REPO=<owner>/<name>)
# The script refuses to run unless the active `gh` account IS that owner
# (user-owned platform) or is an admin of it (organization-owned platform) —
# a guard against deleting repositories from the wrong account.
#
# After the repositories are handled, the script scans the owner's GHCR
# container packages with the same name matching and offers to delete those
# too. Packages outlive their repository (the app CI publishes to
# ghcr.io/<owner>/<repo>), and a recreated repo of the same name CANNOT
# write to the old package — so a lingering package breaks the recreated
# repo's CI push. The package scan runs even when no repositories matched,
# so the script can clean up after repos that were already deleted.
#
# Safety:
#   - Always lists the exact repositories/packages found and requires the
#     user to type an explicit confirmation phrase for each phase.
#   - Confirmations are read from /dev/tty, so they cannot be bypassed by
#     piping input, redirecting stdin, or running non-interactively.
#   - There is deliberately no --yes/--force option.
#   - Each phase is gated independently: declining the repo phrase skips
#     repository deletion and continues to the package check; declining the
#     package phrase keeps the packages. Neither is an error.
#
# Required gh token scopes:
#   - delete_repo                      (repository deletion)
#   - read:packages, delete:packages   (package listing / deletion)
#   gh auth refresh -h github.com -s delete_repo,read:packages,delete:packages

set -euo pipefail

log() { echo "[remove-demo-repos] $*" >&2; }
err() { echo "[remove-demo-repos] ERROR: $*" >&2; exit 1; }
ok()  { echo "[remove-demo-repos] ✓ $*" >&2; }

if [ "$#" -lt 1 ]; then
  echo "usage: $(basename "$0") <base-name> [<base-name> ...]" >&2
  exit 2
fi

if [ ! -e /dev/tty ]; then
  err "no terminal available — this script only runs interactively"
fi

for TOOL in gh jq; do
  command -v "$TOOL" >/dev/null || err "'$TOOL' is required"
done

# This script lives in scripts/local/ of the platform repo checkout.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PLATFORM_REPO="${PLATFORM_REPO:-$(cd "${REPO_ROOT}" && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)}"

# ── Owner: environment → platform repo ───────────────────────────────────────

OWNER="${GITHUB_OWNER:-${PLATFORM_REPO%%/*}}"
[ -n "${OWNER}" ] || err "no owner: set GITHUB_OWNER, or PLATFORM_REPO=<owner>/<name>"
[[ "${OWNER}" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ ]] || err "'${OWNER}' is not a GitHub user or organization name"

# ── Guards ───────────────────────────────────────────────────────────────────

ACTIVE_USER="$(gh api user --jq .login 2>/dev/null || true)"
[ -n "${ACTIVE_USER}" ] || err "gh is not logged in (gh api user failed)"

OWNER_TYPE="$(gh api "users/${OWNER}" --jq .type 2>/dev/null || true)"
case "${OWNER_TYPE}" in
  User)
    if [ "$(tr "[:upper:]" "[:lower:]" <<<"${ACTIVE_USER}")" != "$(tr "[:upper:]" "[:lower:]" <<<"${OWNER}")" ]; then
      err "the active gh account is '${ACTIVE_USER}', not '${OWNER}'; switch with 'gh auth switch -u ${OWNER}' first"
    fi
    PKG_BASE="user/packages"
    ;;
  Organization)
    ROLE="$(gh api "orgs/${OWNER}/memberships/${ACTIVE_USER}" --jq .role 2>/dev/null || true)"
    [ "${ROLE}" = "admin" ] || err "the active gh account '${ACTIVE_USER}' is not an admin of organization '${OWNER}' (role: ${ROLE:-none})"
    PKG_BASE="orgs/${OWNER}/packages"
    ;;
  *)
    err "could not determine whether '${OWNER}' is a user or an organization (gh api users/${OWNER})"
    ;;
esac

log "owner          ${OWNER} (${OWNER_TYPE})"
log "active account ${ACTIVE_USER}"

matches_base() {
  # matches_base <name> <base...> — the shared matching rule: exact or base-*.
  local NAME="$1"; shift
  local BASE
  for BASE in "$@"; do
    if [ "${NAME}" = "${BASE}" ] || [[ "${NAME}" == "${BASE}"-* ]]; then
      return 0
    fi
  done
  return 1
}

# ── Phase 1: repositories ────────────────────────────────────────────────────
log "scanning repositories of ${OWNER}…"

# All repo names of the owner (up to 1000).
ALL_REPOS=$(gh repo list "${OWNER}" --limit 1000 --json name -q '.[].name')

TARGETS=()
for BASE in "$@"; do
  MATCHED=0
  while IFS= read -r NAME; do
    [ -z "${NAME}" ] && continue
    if matches_base "${NAME}" "${BASE}"; then
      TARGETS+=("${NAME}")
      MATCHED=1
    fi
  done <<< "${ALL_REPOS}"
  if [ "${MATCHED}" -eq 0 ]; then
    log "no repositories match '${BASE}' (exact or '${BASE}-*') — may already be deleted"
  fi
done

FAILED=0
if [ "${#TARGETS[@]}" -eq 0 ]; then
  log "no repositories to delete"
else
  # De-duplicate while preserving order.
  UNIQUE_TARGETS=()
  while IFS= read -r NAME; do
    UNIQUE_TARGETS+=("${NAME}")
  done < <(printf '%s\n' "${TARGETS[@]}" | awk '!seen[$0]++')

  COUNT="${#UNIQUE_TARGETS[@]}"
  echo
  echo "The following ${COUNT} repositor$([ "${COUNT}" -eq 1 ] && echo y || echo ies) will be PERMANENTLY deleted from ${OWNER}:"
  echo
  for NAME in "${UNIQUE_TARGETS[@]}"; do
    echo "  - ${OWNER}/${NAME}"
  done
  echo
  echo "This cannot be undone."

  CONFIRM_PHRASE="DELETE ${COUNT} REPOS"
  printf "Type '%s' to confirm (anything else skips repo deletion and moves on to packages): " "${CONFIRM_PHRASE}"
  read -r REPLY < /dev/tty

  if [ "${REPLY}" != "${CONFIRM_PHRASE}" ]; then
    log "repositories kept — moving on to the package check"
  else
    echo
    for NAME in "${UNIQUE_TARGETS[@]}"; do
      if gh repo delete "${OWNER}/${NAME}" --yes; then
        ok "deleted ${OWNER}/${NAME}"
      else
        log "ERROR: failed to delete ${OWNER}/${NAME} (missing delete_repo scope? run: gh auth refresh -h github.com -s delete_repo)"
        FAILED=1
      fi
    done
  fi
fi

# ── Phase 2: lingering GHCR container packages ───────────────────────────────
# The app CI publishes container images to ghcr.io/<owner>/<repo>, and the
# package survives the repository. A recreated repo with the same name cannot
# write to it, so lingering packages must go before the name is reused.
echo
log "scanning container packages of ${OWNER} (GHCR)…"

PKG_ERR=$(mktemp)
if ! ALL_PKGS=$(gh api --paginate "${PKG_BASE}?package_type=container&per_page=100" \
                  --jq '.[].name' 2>"${PKG_ERR}"); then
  log "WARNING: could not list container packages — skipping the package phase"
  sed 's/^/  /' "${PKG_ERR}" >&2
  log "(the gh token needs read:packages and delete:packages; run: gh auth refresh -h github.com -s read:packages,delete:packages)"
  rm -f "${PKG_ERR}"
  exit "${FAILED}"
fi
rm -f "${PKG_ERR}"

PKG_TARGETS=()
while IFS= read -r NAME; do
  [ -z "${NAME}" ] && continue
  # Container package names may carry a sub-path (ghcr.io/<owner>/<repo>/<image>
  # lists as '<repo>/<image>'), so apply the matching rule to the first path
  # component.
  if matches_base "${NAME%%/*}" "$@"; then
    PKG_TARGETS+=("${NAME}")
  fi
done <<< "${ALL_PKGS}"

if [ "${#PKG_TARGETS[@]}" -eq 0 ]; then
  log "no lingering container packages found"
  exit "${FAILED}"
fi

PKG_COUNT="${#PKG_TARGETS[@]}"
echo
echo "The following ${PKG_COUNT} container package$([ "${PKG_COUNT}" -eq 1 ] && echo '' || echo s) linger$([ "${PKG_COUNT}" -eq 1 ] && echo s || echo '') in GHCR (a recreated repo of the same name cannot write to them):"
echo
for NAME in "${PKG_TARGETS[@]}"; do
  echo "  - ghcr.io/${OWNER}/${NAME} (all versions)"
done
echo
echo "This cannot be undone."

PKG_CONFIRM="DELETE ${PKG_COUNT} PACKAGES"
printf "Type '%s' to confirm (anything else keeps the packages): " "${PKG_CONFIRM}"
read -r REPLY < /dev/tty

if [ "${REPLY}" != "${PKG_CONFIRM}" ]; then
  log "packages kept"
  exit "${FAILED}"
fi

echo
for NAME in "${PKG_TARGETS[@]}"; do
  # Container package names may contain '/', which must be URL-encoded.
  ENCODED=$(jq -rn --arg n "${NAME}" '$n|@uri')
  if gh api -X DELETE "${PKG_BASE}/container/${ENCODED}" --silent; then
    ok "deleted package ghcr.io/${OWNER}/${NAME}"
  else
    log "ERROR: failed to delete package ${NAME} (missing delete:packages scope? run: gh auth refresh -h github.com -s delete:packages)"
    FAILED=1
  fi
done

exit "${FAILED}"
