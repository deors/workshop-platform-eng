#!/usr/bin/env bash
# verify-infra.sh
# Asserts that the deployed Web App stack matches the per-environment expectations
# defined in terraform/environments/<env>/main.tf. Runs after `terraform apply`.
#
# Required env: APP_NAME, ENVIRONMENT
# Exit 0 if all checks pass, 1 if any fail.

set -uo pipefail   # no -e: collect all failures, then exit at the end

APP_NAME="${APP_NAME:?APP_NAME is required}"
ENVIRONMENT="${ENVIRONMENT:?ENVIRONMENT is required}"

PREFIX="${APP_NAME}-${ENVIRONMENT}"
RG="rg-${PREFIX}"
ASP="asp-${PREFIX}"
APP="app-${PREFIX}"
PE="pe-${PREFIX}"

PASSES=()
FAILURES=()

pass()  { PASSES+=("$1"); echo "  ✓ $1"; }
fail()  { FAILURES+=("$1"); echo "  ✗ $1"; }

assert_eq() {
  # $1 = label, $2 = actual, $3 = expected
  if [[ "$2" == "$3" ]]; then pass "$1 = $2"
  else fail "$1: expected '$3', got '$2'"; fi
}

assert_ge() {
  # $1 = label, $2 = actual, $3 = expected minimum
  if [[ "$2" -ge "$3" ]] 2>/dev/null; then pass "$1 = $2 (≥ $3)"
  else fail "$1: expected ≥ $3, got '$2'"; fi
}

# ── Per-environment expectations ──────────────────────────────────────────────
case "$ENVIRONMENT" in
  dev)
    EXPECTED_SKU=P0v3; EXPECTED_ZONE=false; EXPECTED_WORKERS=1; EXPECTED_SLOT=false ;;
  staging)
    EXPECTED_SKU=P1v3; EXPECTED_ZONE=false; EXPECTED_WORKERS=1; EXPECTED_SLOT=true ;;
  prod)
    EXPECTED_SKU=P2v3; EXPECTED_ZONE=true;  EXPECTED_WORKERS=3; EXPECTED_SLOT=true ;;
  *)
    echo "Unknown environment: $ENVIRONMENT" >&2; exit 2 ;;
esac

echo "Verifying $APP_NAME / $ENVIRONMENT (RG=$RG)"

# ── Resource group ────────────────────────────────────────────────────────────
echo "::group::Resource group"
RG_STATE=$(az group show -n "$RG" --query properties.provisioningState -o tsv 2>/dev/null || echo "missing")
assert_eq "RG provisioningState" "$RG_STATE" "Succeeded"
echo "::endgroup::"

# ── App Service Plan ──────────────────────────────────────────────────────────
echo "::group::App Service Plan"
ASP_JSON=$(az appservice plan show -n "$ASP" -g "$RG" -o json 2>/dev/null || echo '{}')
assert_eq "ASP SKU"           "$(jq -r '.sku.name      // "missing"' <<<"$ASP_JSON")" "$EXPECTED_SKU"
assert_eq "ASP zoneRedundant" "$(jq -r '.zoneRedundant // false'     <<<"$ASP_JSON")" "$EXPECTED_ZONE"
# .sku.capacity is the authoritative worker count; .numberOfWorkers is unreliable
# across CLI versions and often reports 0 even when capacity is set.
assert_ge "ASP workerCount"   "$(jq -r '.sku.capacity // 0'          <<<"$ASP_JSON")" "$EXPECTED_WORKERS"
echo "::endgroup::"

# ── Web App ───────────────────────────────────────────────────────────────────
echo "::group::Web App"
WA_JSON=$(az webapp show -n "$APP" -g "$RG" -o json 2>/dev/null || echo '{}')
assert_eq "WebApp state"      "$(jq -r '.state         // "missing"' <<<"$WA_JSON")" "Running"
assert_eq "WebApp httpsOnly"  "$(jq -r '.httpsOnly     // false'     <<<"$WA_JSON")" "true"
assert_eq "WebApp identity"   "$(jq -r '.identity.type // "None"'    <<<"$WA_JSON")" "UserAssigned"

CFG_JSON=$(az webapp config show -n "$APP" -g "$RG" -o json 2>/dev/null || echo '{}')
assert_eq "minTlsVersion"     "$(jq -r '.minTlsVersion // "missing"' <<<"$CFG_JSON")" "1.3"
assert_eq "ftpsState"         "$(jq -r '.ftpsState     // "missing"' <<<"$CFG_JSON")" "Disabled"
assert_eq "http20Enabled"     "$(jq -r '.http20Enabled // false'     <<<"$CFG_JSON")" "true"
echo "::endgroup::"

# ── Private Endpoint ──────────────────────────────────────────────────────────
echo "::group::Private Endpoint"
PE_JSON=$(az network private-endpoint show -n "$PE" -g "$RG" -o json 2>/dev/null || echo '{}')
assert_eq "PE provisioningState" "$(jq -r '.provisioningState // "missing"' <<<"$PE_JSON")" "Succeeded"
echo "::endgroup::"

# ── Diagnostic settings ───────────────────────────────────────────────────────
echo "::group::Diagnostic settings"
WA_ID=$(jq -r '.id // ""' <<<"$WA_JSON")
if [[ -n "$WA_ID" ]]; then
  # `az monitor diagnostic-settings list` returns a flat array, not a wrapped
  # {value:[…]} object — use length(@) on the array root.
  DIAG_COUNT=$(az monitor diagnostic-settings list --resource "$WA_ID" --query 'length(@)' -o tsv 2>/dev/null || echo 0)
  assert_ge "WebApp diagnostic settings" "$DIAG_COUNT" 1
fi
echo "::endgroup::"

# ── Staging slot (staging + prod only) ────────────────────────────────────────
if [[ "$EXPECTED_SLOT" == true ]]; then
  echo "::group::Staging slot"
  SLOT_STATE=$(az webapp deployment slot list -n "$APP" -g "$RG" \
    --query "[?name=='staging'].state | [0]" -o tsv 2>/dev/null || echo "missing")
  assert_eq "Staging slot state" "${SLOT_STATE:-missing}" "Running"
  echo "::endgroup::"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
{
  echo "## Verify · \`$APP_NAME\` / \`$ENVIRONMENT\`"
  echo ""
  echo "**Passed:** ${#PASSES[@]} · **Failed:** ${#FAILURES[@]}"
  echo ""
  if [[ ${#FAILURES[@]} -gt 0 ]]; then
    echo "### Failures"
    printf -- '- %s\n' "${FAILURES[@]}"
    echo ""
  fi
  echo "<details><summary>All checks</summary>"
  echo ""
  printf -- '- ✓ %s\n' "${PASSES[@]}"
  [[ ${#FAILURES[@]} -gt 0 ]] && printf -- '- ✗ %s\n' "${FAILURES[@]}"
  echo ""
  echo "</details>"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

# Machine-readable summary for downstream aggregation (uploaded as an
# artifact by the calling workflow). Always written, even on failure.
{
  echo "environment=${ENVIRONMENT}"
  echo "passed=${#PASSES[@]}"
  echo "failed=${#FAILURES[@]}"
} > "${VERIFY_SUMMARY_FILE:-/tmp/verify-summary.txt}"

if [[ ${#FAILURES[@]} -gt 0 ]]; then
  echo
  echo "FAILED: ${#FAILURES[@]} of $((${#PASSES[@]} + ${#FAILURES[@]})) checks"
  exit 1
fi

echo
echo "OK: all ${#PASSES[@]} checks passed."
