#!/usr/bin/env bash
#
# Move the site from one api_backend to another and record what it cost.
#
#   ./switch-mode.sh <from> <to> <checkpoint>
#   ./switch-mode.sh api3 auto 40-auto
#
# The order matters and is the reason --force exists on config-rewrite: the
# plan has to be taken while the configuration still reads as <from>, the
# setting is flipped next, and only then is the rewrite applied. So:
#
#   1. plan     config-rewrite --from --to --force        -> <cp>-plan.json
#   2. flip     cset civicrm_entity.settings api_backend
#   3. audit    api-audit BEFORE cr, to catch routing that only looks right
#               once the container has been rebuilt      -> <cp>-audit-before-cr.json
#   4. cr
#   5. apply    config-rewrite --apply                    -> <cp>-apply.json
#   6. cr
#   7. export   the rewritten configuration to $SET/expected/<from>-to-<to>
#   8. parity   the three-pass comparison                 -> <cp>-parity.json
#   9. verify   the checkpoint, with the HTTP smoke pass
#
# Steps 1, 5 and 8 are allowed to exit non-zero; their exit codes are logged
# and the run continues, because a failure there is a finding, not a crash.

set -euo pipefail

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/upgrade-test/env.sh
source "$_HERE/env.sh"

FROM="${1:-}"
TO="${2:-}"
CP="${3:-}"
[[ -n "$FROM" && -n "$TO" && -n "$CP" ]] || die "usage: switch-mode.sh <from> <to> <checkpoint>"

step "switch-mode $FROM -> $TO ($CP)"

PLAN_RC=0
run_capture "$RUN/$CP-plan.json" "${DRUSH[@]}" civicrm-entity:config-rewrite \
  "--from=$FROM" "--to=$TO" --force --format=json || PLAN_RC=$?
[[ $PLAN_RC -eq 0 ]] || log "  config-rewrite (plan) exited $PLAN_RC; see $RUN/$CP-plan.json"

run "${DRUSH[@]}" cset civicrm_entity.settings api_backend "$TO" -y

AUDIT_RC=0
run_capture "$RUN/$CP-audit-before-cr.json" "${DRUSH[@]}" civicrm-entity:api-audit --format=json || AUDIT_RC=$?
[[ $AUDIT_RC -eq 0 ]] || log "  api-audit (before cr) exited $AUDIT_RC"

run "${DRUSH[@]}" cr

APPLY_RC=0
run_capture "$RUN/$CP-apply.json" "${DRUSH[@]}" civicrm-entity:config-rewrite \
  "--from=$FROM" "--to=$TO" --apply --format=json || APPLY_RC=$?
[[ $APPLY_RC -eq 0 ]] || log "  config-rewrite (apply) exited $APPLY_RC; see $RUN/$CP-apply.json"

run "${DRUSH[@]}" cr

step "switch-mode: recording the rewritten configuration"
run "${DRUSH[@]}" php:script "$SET/export.php" -- "$SET/expected/$FROM-to-$TO" --clean

# Parity compares every mode against the first one named, and an API4-only
# mode makes a poor baseline: an entity it does not support samples no records
# for the other mode to be asked about. Name the compatibility mode first.
PARITY_MODES="$FROM,$TO"
case "$FROM" in
  api4_native|api4_strict) PARITY_MODES="$TO,$FROM" ;;
esac
PARITY_RC=0
run_capture "$RUN/$CP-parity.json" "${DRUSH[@]}" civicrm-entity:parity \
  "--modes=$PARITY_MODES" --limit=25 --format=json || PARITY_RC=$?
[[ $PARITY_RC -eq 0 ]] || log "  parity exited $PARITY_RC (mismatches are reported this way); see $RUN/$CP-parity.json"

run_script "$_HERE/verify.sh" "$CP" --http

log "switch-mode $FROM->$TO: plan=$PLAN_RC audit=$AUDIT_RC apply=$APPLY_RC parity=$PARITY_RC"
printf 'switch-mode %s->%s (%s): plan=%s audit=%s apply=%s parity=%s\n' \
  "$FROM" "$TO" "$CP" "$PLAN_RC" "$AUDIT_RC" "$APPLY_RC" "$PARITY_RC" >> "$RUN/verify-summary.txt"
