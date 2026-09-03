#!/usr/bin/env bash
#
# The whole civicrm_entity 4.0.8 -> 5.0.x upgrade test, end to end.
#
#   ./run-all.sh [--from=<checkpoint>]
#   DRY_RUN=1 ./run-all.sh              print the command sequence, change nothing
#   STOP_AFTER=30-upgraded-api3 ./run-all.sh
#
# Nine steps; each ends in one or two checkpoints, and every checkpoint is both
# a verify.sh comparison against the one before it and a restorable database
# snapshot in $BACKUPS:
#
#   step        checkpoint(s)                  what it does
#   ----------------------------------------------------------------------------
#   pristine    00-pristine                    baseline: 4.0.8, no fixture
#   seeded      10-seeded                      CiviCRM sample data + seed fixture
#   configured  20-configured-4.0.8            generate and export the api3 set
#   reimported  20b-reimported                 restore 20 and import the export
#   upgraded    28-updb-only 30-upgraded-api3  sync 5.0.x, updb, submodules
#   auto        40-auto                        api_backend api3 -> auto
#   api4        50-api4_native                 api_backend auto -> api4_native
#   reverse     60-reverse-api3                api_backend api4_native -> api3
#   pledge      70-pledge-enabled              enable CiviPledge, create a pledge
#
# --from=<checkpoint> restores that checkpoint and continues. When it is the
# last checkpoint of its step the run resumes at the NEXT step; when it is an
# intermediate one (only 28-updb-only is) the run re-enters that same step from
# the top, which is safe because every step is idempotent from its own inputs.
#
# STOP_AFTER=<checkpoint> ends the run once the step producing it is done.
#
# NOBODY MAY RUN COMPOSER ON THE TARGET SITE DURING A RUN. sync-module.sh moves
# the module tree in and out of web/modules/contrib by hand; a composer install
# or update mid-run puts 4.0.8 back underneath a 5.0.x database.

set -euo pipefail

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/upgrade-test/env.sh
source "$_HERE/env.sh"

FROM=''
for arg in "$@"; do
  case "$arg" in
    --from=*) FROM="${arg#--from=}" ;;
    *) die "unknown option: $arg" ;;
  esac
done

STOP_AFTER="${STOP_AFTER:-}"

# ------------------------------------------------------------------ steps ---

step_pristine() {
  step "STEP pristine -> 00-pristine"
  if [[ -d "$BACKUPS/00-pristine" ]]; then
    log "  $BACKUPS/00-pristine already exists; keeping it"
  else
    run_script "$_HERE/snapshot.sh" 00-pristine
  fi
  run_script "$_HERE/verify.sh" 00-pristine --no-snapshot
}

step_seeded() {
  step "STEP seeded -> 10-seeded"
  run_script "$_HERE/seed.sh"
  run_script "$_HERE/verify.sh" 10-seeded
}

step_configured() {
  step "STEP configured -> 20-configured-4.0.8"
  run_script "$_HERE/generate-config.sh"
  run_script "$_HERE/verify.sh" 20-configured-4.0.8
}

step_reimported() {
  step "STEP reimported -> 20b-reimported (round trip through the exported set)"
  run_script "$_HERE/restore.sh" 20-configured-4.0.8
  run_script "$_HERE/import-config-set.sh" --site
  run_script "$_HERE/verify.sh" 20b-reimported --prev=20-configured-4.0.8 --no-snapshot
}

step_upgraded() {
  step "STEP upgraded -> 28-updb-only, 30-upgraded-api3"
  run_script "$_HERE/upgrade.sh"
}

step_auto() {
  step "STEP auto -> 40-auto"
  run_script "$_HERE/switch-mode.sh" api3 auto 40-auto
}

step_api4() {
  step "STEP api4 -> 50-api4_native"
  run_script "$_HERE/switch-mode.sh" auto api4_native 50-api4_native
}

step_reverse() {
  step "STEP reverse -> 60-reverse-api3"
  run_script "$_HERE/switch-mode.sh" api4_native api3 60-reverse-api3
  # Round-tripping back to api3 should land on the set we started from. What is
  # left in the diff is what the rewrite cannot undo.
  run_sh "diff -r $(_quote "$SET/api3/portable") $(_quote "$SET/expected/api4_native-to-api3/portable") > $(_quote "$RUN/60-reverse-diff.txt") || true"
}

step_pledge() {
  step "STEP pledge -> 70-pledge-enabled"
  run "${CV[@]}" ev 'CRM_Core_BAO_ConfigSetting::enableComponent("CiviPledge");'
  run "${CV[@]}" flush
  # Tolerated: the point is that enabling a component mid-life adds entity
  # types, not that this particular pledge is creatable on every fixture.
  run "${CV[@]}" api4 Pledge.create '{"values":{"contact_id":1,"amount":100,"installments":1,"frequency_unit":"month","start_date":"2026-09-01","financial_type_id":1,"currency":"USD"}}' \
    || log "  Pledge.create failed; continuing (the entity types are what matter here)"
  run "${DRUSH[@]}" cr
  run_script "$_HERE/verify.sh" 70-pledge-enabled --http
}

# The table, defined once. Index i pairs STEP_FUNCS[i] with the whitespace
# separated checkpoint names STEP_CHECKPOINTS[i] produces, in order.
STEP_FUNCS=(
  step_pristine
  step_seeded
  step_configured
  step_reimported
  step_upgraded
  step_auto
  step_api4
  step_reverse
  step_pledge
)
STEP_CHECKPOINTS=(
  '00-pristine'
  '10-seeded'
  '20-configured-4.0.8'
  '20b-reimported'
  '28-updb-only 30-upgraded-api3'
  '40-auto'
  '50-api4_native'
  '60-reverse-api3'
  '70-pledge-enabled'
)

all_checkpoints() {
  local group
  for group in "${STEP_CHECKPOINTS[@]}"; do
    printf '%s\n' $group
  done
}

# ----------------------------------------------------------------- resume ---

START=0
if [[ -n "$FROM" ]]; then
  FOUND=-1
  IS_LAST=0
  for i in "${!STEP_CHECKPOINTS[@]}"; do
    # shellcheck disable=SC2206
    group=(${STEP_CHECKPOINTS[$i]})
    for j in "${!group[@]}"; do
      if [[ "${group[$j]}" == "$FROM" ]]; then
        FOUND=$i
        if [[ $j -eq $(( ${#group[@]} - 1 )) ]]; then IS_LAST=1; fi
      fi
    done
  done
  if [[ $FOUND -lt 0 ]]; then
    die "--from=$FROM is not a checkpoint of this run; known: $(all_checkpoints | tr '\n' ' ')"
  fi
  step "resuming from $FROM"
  run_script "$_HERE/restore.sh" "$FROM"
  # The first checkpoint of a resumed run has no predecessor in $RUN; verify.sh
  # compares it against this checkpoint's JSON from the run that recorded it.
  export RESUMED_FROM="$FROM"
  if [[ $IS_LAST -eq 1 ]]; then
    START=$(( FOUND + 1 ))
    log "  $FROM is the last checkpoint of ${STEP_FUNCS[$FOUND]}; resuming at the next step"
  else
    START=$FOUND
    log "  $FROM is an intermediate checkpoint of ${STEP_FUNCS[$FOUND]}; re-entering that step"
  fi
fi

# -------------------------------------------------------------------- run ---

: > "$RUN/verify-summary.txt"
log ""
log "run id     $RUN_ID"
log "run dir    $RUN"
log "site       $SITE ($URI)"
log "module     $(module_version) at $MODULE_DST"
log "backups    $BACKUPS"
log "dry run    $DRY_RUN"
[[ -n "$STOP_AFTER" ]] && log "stop after $STOP_AFTER"

if [[ $START -ge ${#STEP_FUNCS[@]} ]]; then
  log ""
  log "--from named the last checkpoint of the run; the site was restored and there is nothing left to do"
fi

for (( i = START; i < ${#STEP_FUNCS[@]}; i++ )); do
  "${STEP_FUNCS[$i]}"
  if [[ -n "$STOP_AFTER" ]]; then
    for cp in ${STEP_CHECKPOINTS[$i]}; do
      if [[ "$cp" == "$STOP_AFTER" ]]; then
        log ""
        log "STOP_AFTER=$STOP_AFTER reached; stopping after ${STEP_FUNCS[$i]}"
        break 2
      fi
    done
  fi
done

# ---------------------------------------------------------------- summary ---

{
  printf 'civicrm_entity upgrade test\n'
  printf 'run id   %s\n' "$RUN_ID"
  printf 'site     %s (%s)\n' "$SITE" "$URI"
  if [[ $START -lt ${#STEP_FUNCS[@]} ]]; then
    printf 'started  from step %s\n' "${STEP_FUNCS[$START]}"
  else
    printf 'started  nothing to do; --from named the final checkpoint\n'
  fi
  printf 'dry run  %s\n\n' "$DRY_RUN"
  if [[ -s "$RUN/verify-summary.txt" ]]; then
    cat "$RUN/verify-summary.txt"
  else
    printf '(no verify lines recorded)\n'
  fi
} > "$RUN/SUMMARY.txt"

log ""
log "SUMMARY -> $RUN/SUMMARY.txt"
cat "$RUN/SUMMARY.txt" >&2
