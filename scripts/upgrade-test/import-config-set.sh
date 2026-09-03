#!/usr/bin/env bash
#
# Import an exported config set onto the target site.
#
#   ./import-config-set.sh [--set=DIR] [--site]
#
#   --set=DIR   the set root to import (default $SET/api3)
#   --site      also import <set>/site, the site-shaped configuration that
#               carries UUIDs and is not portable between sites
#
# This is the reusable import path: the round trip at 20b uses it to prove the
# exported set restores what generate-config.sh built, and it is the way to put
# the baseline configuration onto a site that never ran the generator.
#
# The 5.0.x submodules are enabled only when they exist, so the same script
# works on 4.0.8, where civicrm_entity ships no split submodules for rules,
# search_api, VBO or bundles.
#
# `config:import --partial` is expected to report failures on a set that
# references configuration this site does not have; they are logged and the
# run continues, and verify.sh is what decides whether the result is usable.

set -euo pipefail

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/upgrade-test/env.sh
source "$_HERE/env.sh"

SET_ROOT="$SET/api3"
WITH_SITE=0
for arg in "$@"; do
  case "$arg" in
    --set=*) SET_ROOT="${arg#--set=}" ;;
    --site) WITH_SITE=1 ;;
    *) die "unknown option: $arg" ;;
  esac
done

SITE_LABEL=''
if [[ $WITH_SITE -eq 1 ]]; then SITE_LABEL=' (+site)'; fi
step "import-config-set: ${SET_ROOT}${SITE_LABEL}"
set_root_check "$SET_ROOT"

run "${DRUSH[@]}" en -y config rules typed_data search_api search_api_db views_bulk_operations

if [[ -d "$MODULE_DST/modules/civicrm_entity_bundles" ]]; then
  log "  5.0.x layout detected; enabling the split submodules"
  run "${DRUSH[@]}" en -y civicrm_entity_bundles civicrm_entity_rules civicrm_entity_search_api civicrm_entity_vbo
else
  log "  4.0.8 layout: no split submodules to enable"
fi

run "${DRUSH[@]}" php:script "$SET/apply-settings.php" -- "$SET_ROOT/settings/civicrm_entity.settings.yml"
run "${DRUSH[@]}" cr

import_partial() {
  local source="$1" rc=0
  run "${DRUSH[@]}" config:import --partial "--source=$source" -y || rc=$?
  if [[ $rc -ne 0 ]]; then
    log "  config:import --source=$source exited $rc; continuing (partial imports are expected to report misses)"
  fi
  return 0
}

import_partial "$SET_ROOT/portable"
if [[ $WITH_SITE -eq 1 ]]; then
  import_partial "$SET_ROOT/site"
fi

run "${DRUSH[@]}" cr
log "import-config-set: done ($SET_ROOT)"
