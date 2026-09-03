#!/usr/bin/env bash
#
# Upgrade the target site from civicrm_entity 4.0.8 to the 5.0.x working tree.
#
#   ./upgrade.sh
#
# Swap the code, run the database updates, verify, enable the submodules 5.0.x
# split out of the main module, verify again. The two checkpoints are separate
# on purpose: 28-updb-only isolates what the update hooks alone did, so a
# regression at 30 can be attributed to the submodules rather than to updb.
#
# SIMULATE_MISSING_TYPES=1 uninstalls the two pledge entity types before updb.
# That is SYNTHETIC: it fabricates the state of a site whose CiviPledge
# component was never enabled, so the update hooks are exercised against an
# entity type definition that is absent rather than merely stale. No real site
# reaches this state by itself, and the flag is off by default.

set -euo pipefail

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/upgrade-test/env.sh
source "$_HERE/env.sh"

step "upgrade: swapping in the 5.0.x working tree"
run_script "$_HERE/sync-module.sh" 5.0.x

if [[ "$SIMULATE_MISSING_TYPES" == "1" ]]; then
  step "upgrade: SYNTHETIC -- uninstalling the pledge entity types before updb"
  run "${DRUSH[@]}" ev '$m=\Drupal::entityDefinitionUpdateManager(); foreach(["civicrm_pledge","civicrm_pledge_payment"] as $t){ if($e=$m->getEntityType($t)){ $m->uninstallEntityType($e); echo "uninstalled $t\n"; } }'
fi

step "upgrade: running database updates"
UPDB_RC=0
run_tee "$RUN/updb.log" "${DRUSH[@]}" updb -y || UPDB_RC=$?
if [[ $UPDB_RC -ne 0 ]]; then
  log "  warning: updb exited $UPDB_RC; see $RUN/updb.log"
fi

run_script "$_HERE/verify.sh" 28-updb-only

step "upgrade: enabling the 5.0.x submodules"
EN_RC=0
run_tee "$RUN/enable-submodules.log" "${DRUSH[@]}" en -y \
  civicrm_entity_bundles civicrm_entity_rules civicrm_entity_search_api civicrm_entity_vbo || EN_RC=$?
if [[ $EN_RC -ne 0 ]]; then
  log "  warning: enabling the submodules exited $EN_RC; see $RUN/enable-submodules.log"
fi
run "${DRUSH[@]}" cr

run_script "$_HERE/verify.sh" 30-upgraded-api3 --http

log "upgrade: done (updb rc=$UPDB_RC, submodules rc=$EN_RC)"
