#!/usr/bin/env bash
#
# Roll the target site back to a named checkpoint.
#
#   ./restore.sh <name>
#
# Drops and recreates both databases, loads the checkpoint's dumps, puts the
# module version the checkpoint recorded back in place, and flushes both
# caches. The dumps already carry --add-drop-database; the explicit DROP /
# CREATE is kept so the character set is stated rather than inherited.
#
# THIS DESTROYS THE CURRENT STATE OF BOTH DATABASES.

set -euo pipefail

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/upgrade-test/env.sh
source "$_HERE/env.sh"

NAME="${1:-}"
[[ -n "$NAME" ]] || die "usage: restore.sh <name>"

SRC="$BACKUPS/$NAME"
VERSION=''
if [[ -d "$SRC" ]]; then
  require_file "$SRC/drupal.sql.gz" "checkpoint $NAME drupal dump"
  require_file "$SRC/civicrm.sql.gz" "checkpoint $NAME civicrm dump"
  require_file "$SRC/module-version" "checkpoint $NAME module-version"
  VERSION="$(tr -d '[:space:]' < "$SRC/module-version")"
  [[ -n "$VERSION" ]] || die "checkpoint $NAME has an empty module-version"
elif [[ "$DRY_RUN" == "1" ]]; then
  # The checkpoint is taken by an earlier step of the run being rehearsed.
  log "  (dry run) checkpoint $NAME has not been taken yet"
else
  die "checkpoint $NAME is missing at $SRC"
fi

step "restore $NAME (module ${VERSION:-<from $SRC/module-version>}, taken $(cat "$SRC/taken-at" 2>/dev/null || echo unknown))"

restore_db() {
  local db="$1" dump="$2"
  run "${MYSQL[@]}" -e "DROP DATABASE IF EXISTS \`$db\`; CREATE DATABASE \`$db\` CHARACTER SET utf8mb4;"
  run_sh "gzip -dc $(_quote "$dump") | $(_quote "${MYSQL[@]}")"
}

restore_db "$DRUPAL_DATABASE" "$SRC/drupal.sql.gz"
restore_db "$CIVICRM_DATABASE" "$SRC/civicrm.sql.gz"

if [[ -n "$VERSION" ]]; then
  run_script "$_HERE/sync-module.sh" "$VERSION"
else
  log "  > $_HERE/sync-module.sh \$(cat $SRC/module-version)"
fi
run "${CV[@]}" flush
run "${DRUSH[@]}" cr

log "restore $NAME: $DRUPAL_DATABASE + $CIVICRM_DATABASE reloaded, module now $(module_version)"
