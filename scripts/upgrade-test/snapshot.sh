#!/usr/bin/env bash
#
# Take a named checkpoint of the target site's two databases.
#
#   ./snapshot.sh <name> [--force]
#
# Writes $BACKUPS/<name>/ with:
#   drupal.sql.gz    mysqldump --add-drop-database --databases $DRUPAL_DATABASE
#   civicrm.sql.gz   mysqldump --add-drop-database --databases $CIVICRM_DATABASE
#   module-version   4.0.8 or 5.0.x -- what restore.sh syncs the code back to
#   taken-at         ISO 8601 timestamp
#
# The dumps carry --add-drop-database and --databases so restoring one is a
# single load with no manual CREATE DATABASE.
#
# The first time it sees a 4.0.8 module it also archives the code to
# $BACKUPS/module-4.0.8.tar.gz, because 4.0.8 comes from composer and nothing
# else in this harness can reconstruct it. An existing archive is left alone.
#
# Refuses to overwrite an existing checkpoint unless --force.
#
# This script only reads from the site, so it is safe to run at any time.

set -euo pipefail

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/upgrade-test/env.sh
source "$_HERE/env.sh"

NAME=''
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    -*) die "unknown option: $arg" ;;
    *) [[ -z "$NAME" ]] || die "one checkpoint name at a time (got '$NAME' and '$arg')"; NAME="$arg" ;;
  esac
done
[[ -n "$NAME" ]] || die "usage: snapshot.sh <name> [--force]"

DEST="$BACKUPS/$NAME"
if [[ -d "$DEST" && $FORCE -ne 1 ]]; then
  die "checkpoint $NAME already exists at $DEST; pass --force to replace it"
fi

step "snapshot $NAME"
VERSION="$(module_version)"
log "  module version: $VERSION"

run mkdir -p "$DEST"
run_sh "$(_quote "${MYSQLDUMP[@]}" --add-drop-database --databases "$DRUPAL_DATABASE") | gzip > $(_quote "$DEST/drupal.sql.gz")"
run_sh "$(_quote "${MYSQLDUMP[@]}" --add-drop-database --databases "$CIVICRM_DATABASE") | gzip > $(_quote "$DEST/civicrm.sql.gz")"
run_sh "printf '%s\n' $(_quote "$VERSION") > $(_quote "$DEST/module-version")"
run_sh "date -Iseconds > $(_quote "$DEST/taken-at")"

if [[ ! -f "$BACKUPS/module-4.0.8.tar.gz" && "$VERSION" == "4.0.8" ]]; then
  log "  archiving the 4.0.8 module tree (composer is the only other source of it)"
  run tar -C "$SITE/web/modules/contrib" -czf "$BACKUPS/module-4.0.8.tar.gz" civicrm_entity
fi

if [[ "$DRY_RUN" != "1" ]]; then
  log "snapshot $NAME: $(du -sh "$DEST" | cut -f1) at $DEST (module $VERSION)"
else
  log "snapshot $NAME: would write $DEST (module $VERSION)"
fi
