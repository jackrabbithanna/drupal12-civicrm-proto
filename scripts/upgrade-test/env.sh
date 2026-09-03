#!/usr/bin/env bash
#
# Environment for the civicrm_entity upgrade test harness.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
#
# Sourced by every script in this directory; loading it twice is a no-op. It
# resolves the two repositories involved, reads the target site's database
# credentials out of its own .env rather than hard-coding them, and builds the
# drush / cv / mysql / mysqldump argv arrays the rest of the harness uses.
#
# Overridable from the environment:
#   SITE                    target site root      (default /var/www/web/distro11-upsun)
#   URI                     target site URL       (default http://distro11.upsun.me)
#   BACKUPS                 checkpoint store      (default ~/db-backups/ce-upgrade-test)
#   RUN_ID                  run directory name    (default YYYYmmdd-HHMM)
#   DRY_RUN=1               echo state-changing commands instead of running them
#   SIMULATE_MISSING_TYPES  1 to uninstall the pledge entity types before updb
#   HTTP_SMOKE              0 to suppress the HTTP smoke pass even with --http
#
# The two sanity checks -- the site bootstraps, and config_readonly is off --
# run once per process tree; UPGRADE_TEST_SANITY_DONE=1 is exported so the
# child scripts run-all.sh invokes do not repeat them.

if [[ -n "${_CE_UPGRADE_ENV_LOADED:-}" ]]; then
  return 0
fi
_CE_UPGRADE_ENV_LOADED=1

_CE_ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/upgrade-test/lib.sh
source "$_CE_ENV_DIR/lib.sh"

# ------------------------------------------------------------------- paths ---

PROTO="$(cd "$_CE_ENV_DIR/../.." && pwd)"
SITE="${SITE:-/var/www/web/distro11-upsun}"
URI="${URI:-http://distro11.upsun.me}"

MODULE_SRC="$PROTO/web/modules/contrib/civicrm_entity"
MODULE_DST="$SITE/web/modules/contrib/civicrm_entity"
SET="$MODULE_SRC/tests/fixtures/config-set"
HARNESS="$MODULE_SRC/tests/fixtures/upgrade-harness"

BACKUPS="${BACKUPS:-$HOME/db-backups/ce-upgrade-test}"
RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M)}"
RUN="$PROTO/scripts/upgrade-test/out/$RUN_ID"
mkdir -p "$RUN"

DRY_RUN="${DRY_RUN:-0}"
SIMULATE_MISSING_TYPES="${SIMULATE_MISSING_TYPES:-0}"
HTTP_SMOKE="${HTTP_SMOKE:-1}"

require_dir "$PROTO" 'proto repository root'
require_dir "$SITE" 'target site root'
require_dir "$MODULE_SRC" '5.0.x module source'

export PROTO SITE URI MODULE_SRC MODULE_DST SET HARNESS BACKUPS RUN_ID RUN
export DRY_RUN SIMULATE_MISSING_TYPES HTTP_SMOKE

# ------------------------------------------------------------- credentials ---

require_file "$SITE/.env" 'the site .env holding the database credentials'
set -a
# shellcheck disable=SC1091
source "$SITE/.env"
set +a

DATABASE_PORT="${DATABASE_PORT:-3306}"
: "${DATABASE_HOST:?DATABASE_HOST is not set in $SITE/.env}"
: "${DATABASE_USER:?DATABASE_USER is not set in $SITE/.env}"
: "${DATABASE_PASSWORD:?DATABASE_PASSWORD is not set in $SITE/.env}"
: "${DRUPAL_DATABASE:?DRUPAL_DATABASE is not set in $SITE/.env}"
: "${CIVICRM_DATABASE:?CIVICRM_DATABASE is not set in $SITE/.env}"
export DATABASE_HOST DATABASE_PORT DATABASE_USER DATABASE_PASSWORD
export DRUPAL_DATABASE CIVICRM_DATABASE

# scripts/load-civicrm-sample-data.sh reads these; pin them to this run's target
# so the loader can never be pointed at the proto site by a stale .env value.
export SITE_ROOT="$SITE"
export SITE_URI="$URI"

# ------------------------------------------------------------------- tools ---

DRUSH=("$SITE/vendor/bin/drush" -l "$URI" --no-interaction)
CV=("$SITE/vendor/bin/cv" "--cwd=$SITE/web")
MYSQL=(mysql --host="$DATABASE_HOST" --port="$DATABASE_PORT" --user="$DATABASE_USER" "--password=$DATABASE_PASSWORD")
MYSQLDUMP=(mysqldump --host="$DATABASE_HOST" --port="$DATABASE_PORT" --user="$DATABASE_USER" "--password=$DATABASE_PASSWORD"
  --single-transaction --routines --triggers)

# ------------------------------------------------------------------ sanity ---

if [[ "${UPGRADE_TEST_SANITY_DONE:-0}" != "1" ]]; then
  [[ -x "${DRUSH[0]}" ]] || die "drush not executable at ${DRUSH[0]}"
  [[ -x "${CV[0]}" ]] || die "cv not executable at ${CV[0]}"

  _ce_bootstrap="$("${DRUSH[@]}" status --field=bootstrap 2>/dev/null || true)"
  [[ "$_ce_bootstrap" == *Successful* ]] \
    || die "drush cannot bootstrap $URI (status --field=bootstrap said '${_ce_bootstrap}')"

  _ce_readonly="$("${DRUSH[@]}" ev 'echo \Drupal\Core\Site\Settings::get("config_readonly") ? "1" : "0";' 2>/dev/null || true)"
  [[ "$_ce_readonly" == "0" ]] \
    || die "config_readonly is enabled on $URI; the run rewrites configuration and would fail halfway"

  unset _ce_bootstrap _ce_readonly
  export UPGRADE_TEST_SANITY_DONE=1
fi
