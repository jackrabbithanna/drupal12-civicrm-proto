#!/usr/bin/env bash
#
# Build the canonical api3 config set on the target site and export it.
#
#   ./generate-config.sh [extra args for generate.php]
#   ./generate-config.sh --layout-builder
#
# Enables the modules the generated configuration depends on, applies the
# module settings the set was authored under, generates the views / fields /
# displays / rules / search indexes, and exports the result over
# $SET/api3 with --clean so a rerun cannot leave stale files behind.
#
# Extra arguments are passed through to generate.php, after `--`.
#
# Run this on 4.0.8: $SET/api3 is the api3-authored baseline the upgrade is
# measured against. The `git status` line at the end shows what moved.

set -euo pipefail

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/upgrade-test/env.sh
source "$_HERE/env.sh"

step "generate-config: enabling the dependency modules"
run "${DRUSH[@]}" en -y config rules typed_data search_api search_api_db views_bulk_operations

step "generate-config: applying every settings profile"
run "${DRUSH[@]}" php:script "$SET/apply-settings.php" -- --all
run "${DRUSH[@]}" cr

GEN_LABEL=''
if [[ $# -gt 0 ]]; then GEN_LABEL=" ($*)"; fi
step "generate-config: generating configuration${GEN_LABEL}"
if [[ $# -gt 0 ]]; then
  run "${DRUSH[@]}" php:script "$SET/generate.php" -- "$@"
else
  run "${DRUSH[@]}" php:script "$SET/generate.php"
fi
run "${DRUSH[@]}" cr

step "generate-config: exporting to $SET/api3"
run "${DRUSH[@]}" php:script "$SET/export.php" -- "$SET/api3" --clean

step "generate-config: what changed in the fixture"
ro git -C "$MODULE_SRC" status --short tests/fixtures/config-set | head || true
