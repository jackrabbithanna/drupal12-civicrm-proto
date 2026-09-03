#!/usr/bin/env bash
#
# Fill the target site's CiviCRM with the fixture the parity checks measure.
#
#   ./seed.sh
#
# Four stages, all logged to $RUN/seed.log:
#   1. enable CiviCase and CiviCampaign -- the sample data and the fixture
#      script both need them, and a stock install has neither;
#   2. load CiviCRM's generated sample data into the existing database
#      (scripts/load-civicrm-sample-data.sh, which backs up first);
#   3. run the module's seed fixture for the entity types the dump leaves
#      empty, plus the multi-valued serialized and custom data;
#   4. rebuild Drupal's caches, because step 2 and 3 changed the CiviCRM
#      schema that civicrm_entity derives its entity definitions from.
#
# THIS TRUNCATES CIVICRM TABLES. Take a checkpoint first.

set -euo pipefail

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/upgrade-test/env.sh
source "$_HERE/env.sh"

LOG="$RUN/seed.log"
: > "$LOG"

step "seed: enabling CiviCase and CiviCampaign"
run_tee "$LOG" "${CV[@]}" ev 'CRM_Core_BAO_ConfigSetting::enableComponent("CiviCase"); CRM_Core_BAO_ConfigSetting::enableComponent("CiviCampaign"); echo "components enabled";'
run_tee "$LOG" "${CV[@]}" flush

step "seed: loading CiviCRM sample data into $CIVICRM_DATABASE"
require_file "$PROTO/scripts/load-civicrm-sample-data.sh" 'the sample data loader'
run_tee "$LOG" "$PROTO/scripts/load-civicrm-sample-data.sh" --yes "--root=$SITE" "--database=$CIVICRM_DATABASE"

step "seed: running the fixture script"
require_file "$MODULE_SRC/tests/fixtures/seed-civicrm-fixture.php" 'the seed fixture'
run_tee "$LOG" "${DRUSH[@]}" php:script "$MODULE_SRC/tests/fixtures/seed-civicrm-fixture.php"

step "seed: rebuilding caches"
run_tee "$LOG" "${DRUSH[@]}" cr

log "seed: done, log at $LOG"
