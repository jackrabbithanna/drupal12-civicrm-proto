#!/usr/bin/env bash
#
# Put one version of civicrm_entity in place on the target site.
#
#   ./sync-module.sh 4.0.8    restore the archived composer install
#   ./sync-module.sh 5.0.x    rsync the proto working tree over it
#
# 4.0.8 comes from $BACKUPS/module-4.0.8.tar.gz, taken once by snapshot.sh.
# 5.0.x comes from $MODULE_SRC -- the proto checkout -- with --delete, so files
# 4.0.8 had and 5.0.x dropped do not linger and get autoloaded.
#
# A container built against the old code can fatal the first time it is asked
# to rebuild after the swap, so `drush cr` is retried once before giving up.

set -euo pipefail

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/upgrade-test/env.sh
source "$_HERE/env.sh"

TARGET="${1:-}"
[[ -n "$TARGET" ]] || die "usage: sync-module.sh 4.0.8|5.0.x"

step "sync-module $TARGET"

case "$TARGET" in
  4.0.8)
    require_file "$BACKUPS/module-4.0.8.tar.gz" 'the archived 4.0.8 module tree'
    run rm -rf "$MODULE_DST"
    run tar -C "$SITE/web/modules/contrib" -xzf "$BACKUPS/module-4.0.8.tar.gz"
    ;;
  5.0.x)
    require_dir "$MODULE_SRC" 'the proto 5.0.x checkout'
    run rsync -a --delete --exclude=.git "$MODULE_SRC/" "$MODULE_DST/"
    ;;
  *)
    die "unknown module version '$TARGET'; expected 4.0.8 or 5.0.x"
    ;;
esac

if ! run "${DRUSH[@]}" cr; then
  log "  cr failed against the swapped-in code; retrying once"
  run "${DRUSH[@]}" cr || die "drush cr still fails after syncing $TARGET"
fi

if [[ "$DRY_RUN" == "1" ]]; then
  log "sync-module: (dry run) $MODULE_DST left as $(module_version); a real run would make it $TARGET"
else
  log "sync-module: $MODULE_DST is now $(module_version)"
fi
