#!/usr/bin/env bash
#
# Load CiviCRM's generated sample data into an existing CiviCRM database.
#
#   ./scripts/load-civicrm-sample-data.sh --yes [--root=PATH] [--database=NAME]
#   ./scripts/load-civicrm-sample-data.sh --dry-run [--root=PATH]
#
# `sql/civicrm_generated.mysql` in civicrm-core is what the installer sources
# when you ask for sample data, and it assumes a database that has just been
# created. This loads it into one that has been in use, which needs three
# things the installer never has to do:
#
#   1. Skip the tables where the local database has diverged. Core seed data
#      (countries, financial types, tags) is already identical, and the
#      registry tables are a local superset -- civicrm_extension has 24 rows
#      here against the dump's 14, so loading the dump's copy would deregister
#      civigrant, search_kit, afform and the rest.
#   2. Drop CiviCRM's triggers first. civicrm_relationship_after_insert fills
#      civicrm_relationship_cache, so loading the dump's relationships
#      populates the cache table and the dump's own cache rows then collide on
#      the primary key. A fresh install creates triggers *after* the load.
#   3. Give every Drupal user a contact again. civicrm_uf_match is not in the
#      dump, so its rows survive while the contacts they point at are replaced.
#
# Which site it acts on:
#
#   --root=PATH   the site to load into. Beats everything else.
#   SITE_ROOT     the same thing from the environment.
#   (neither)     the repository this script lives in.
#
# The dump and drush both come from that root, so pointing --root at another
# site loads THAT site's copy of civicrm_generated.mysql through THAT site's
# drush -- which is what makes this usable from the upgrade test harness in
# scripts/upgrade-test against a site that is not this one.
#
#   SITE_URI      passed to drush as -l when set; needed on a multisite or when
#                 the site's URL cannot be guessed from the filesystem.
#   BACKUP_DIR    where the pre-load backup goes (default ~/db-backups).
#
# THIS TRUNCATES 49 TABLES. It backs up first and refuses to run without
# --yes. --dry-run stops after filtering the dump, having changed nothing but
# the backup file, and reports what the real run would do.
#
# Afterwards, run web/modules/contrib/civicrm_entity/tests/fixtures/seed-civicrm-fixture.php for the nine entity
# types the dump leaves empty.
#
# The two drush steps after the load -- the trigger/cache rebuild and the
# uf_match repointing -- print their output when they fail rather than
# swallowing it. A failed rebuild is fatal, because the triggers the load
# dropped are not back; a failed repointing is a warning, because the data is
# loaded and only the Drupal users' contact links are missing.
#
# @see docs/parity-fixture-and-harness.md

set -euo pipefail

SELF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { printf '\nerror: %s\n' "$1" >&2; exit 1; }

CONFIRMED=0
DRY_RUN=0
DATABASE=""
ROOT_ARG=""
for arg in "$@"; do
  case "$arg" in
    --yes) CONFIRMED=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --root=*) ROOT_ARG="${arg#--root=}" ;;
    --database=*) DATABASE="${arg#--database=}" ;;
    *) die "unknown option: $arg" ;;
  esac
done

# --root= beats SITE_ROOT beats the repository this script is in.
ROOT="${ROOT_ARG:-${SITE_ROOT:-$SELF_ROOT}}"
[[ -d "$ROOT" ]] || die "site root not found: $ROOT"
ROOT="$(cd "$ROOT" && pwd)"

DUMP="$ROOT/vendor/civicrm/civicrm-core/sql/civicrm_generated.mysql"
BACKUP_DIR="${BACKUP_DIR:-$HOME/db-backups}"

DRUSH=("$ROOT/vendor/bin/drush")
if [[ -n "${SITE_URI:-}" ]]; then
  DRUSH+=(-l "$SITE_URI")
fi
[[ -x "${DRUSH[0]}" ]] || die "${DRUSH[0]} not found; is --root=$ROOT the site root?"

if [[ $CONFIRMED -ne 1 && $DRY_RUN -ne 1 ]]; then
  awk 'NR >= 3 { if (/^# @see/) exit; print }' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  die "refusing to truncate without --yes"
fi

[[ -f "$DUMP" ]] || die "$DUMP not found; is civicrm/civicrm-core installed under $ROOT?"

# Credentials come from the site rather than this script.
read -r DB_HOST DB_PORT DB_USER DB_PASS DB_NAME < <(
  "${DRUSH[@]}" ev 'ob_end_clean(); $d = \Drupal\Core\Database\Database::getConnectionInfo("default")["default"];
    printf("%s %s %s %s %s\n", $d["host"], $d["port"] ?: 3306, $d["username"], $d["password"], $d["database"]);' 2>/dev/null
) || die "could not read the database connection from Drupal at $ROOT"

[[ -n "$DATABASE" ]] && DB_NAME="$DATABASE"
[[ -n "$DB_NAME" ]] || die "no database name resolved"

MYSQL=(mysql --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USER" "--password=$DB_PASS" "$DB_NAME")

if [[ $DRY_RUN -eq 1 ]]; then
  printf 'DRY RUN -- site %s, database %s\n' "$ROOT" "$DB_NAME"
  printf '          dump  %s\n' "$DUMP"
  printf '          drush %s\n\n' "${DRUSH[*]}"
fi

# Tables the dump populates that hold transactional data. Everything else the
# dump touches is either already identical here or a local superset.
LOAD_TABLES=(
  civicrm_acl civicrm_acl_entity_role civicrm_activity civicrm_activity_contact
  civicrm_address civicrm_contact civicrm_contact_type civicrm_contribution
  civicrm_contribution_page civicrm_contribution_recur civicrm_contribution_soft
  civicrm_custom_field civicrm_custom_group civicrm_email
  civicrm_entity_financial_trxn civicrm_entity_tag civicrm_event
  civicrm_financial_item civicrm_financial_trxn civicrm_group
  civicrm_group_contact civicrm_line_item civicrm_loc_block civicrm_membership
  civicrm_membership_block civicrm_membership_log civicrm_membership_payment
  civicrm_membership_type civicrm_note civicrm_participant
  civicrm_participant_payment civicrm_pcp civicrm_pcp_block civicrm_phone
  civicrm_pledge civicrm_pledge_block civicrm_pledge_payment civicrm_premiums
  civicrm_premiums_product civicrm_price_field civicrm_price_field_value
  civicrm_price_set civicrm_price_set_entity civicrm_product
  civicrm_relationship civicrm_relationship_cache civicrm_subscription_history
  civicrm_uf_join civicrm_website
)

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$BACKUP_DIR"
BACKUP="$BACKUP_DIR/$DB_NAME.pre-sample-data.$(date +%Y%m%d-%H%M%S).sql.gz"
printf 'backing up %s to %s ... ' "$DB_NAME" "$BACKUP"
mysqldump --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USER" "--password=$DB_PASS" \
  --single-transaction --routines --triggers "$DB_NAME" 2>/dev/null | gzip > "$BACKUP"
printf 'done (%s)\n' "$(du -h "$BACKUP" | cut -f1)"

printf 'dropping triggers ... '
"${MYSQL[@]}" -N -e "SELECT CONCAT('DROP TRIGGER IF EXISTS \`', trigger_name, '\`;')
  FROM information_schema.triggers WHERE trigger_schema = '$DB_NAME';" 2>/dev/null > "$WORK/drop_triggers.sql"
if [[ $DRY_RUN -eq 1 ]]; then
  printf 'would drop %d\n' "$(grep -c . "$WORK/drop_triggers.sql" || true)"
else
  "${MYSQL[@]}" < "$WORK/drop_triggers.sql" 2>/dev/null
  printf '%d dropped\n' "$(grep -c . "$WORK/drop_triggers.sql" || true)"
fi

printf 'truncating %d tables ... ' "${#LOAD_TABLES[@]}"
{
  echo "SET FOREIGN_KEY_CHECKS=0;"
  for table in "${LOAD_TABLES[@]}"; do echo "TRUNCATE TABLE \`$table\`;"; done
  echo "TRUNCATE TABLE \`civicrm_payment_processor\`;"
  echo "DELETE FROM \`civicrm_entity_financial_account\` WHERE entity_table = 'civicrm_payment_processor';"
  # The dump's tail recreates these three.
  echo "DROP TABLE IF EXISTS \`civicrm_value_constituent_information_1\`;"
  echo "DROP TABLE IF EXISTS \`civicrm_value_food_preference_2\`;"
  echo "DROP TABLE IF EXISTS \`civicrm_value_donor_information_3\`;"
  # The tail also creates four option groups, by name and without IDs, so a
  # second run of this script collides on civicrm_option_group.UI_name. They
  # belong to the sample custom fields that were just truncated, so removing
  # them is what makes the load repeatable.
  for group in custom_most_important_issue custom_marital_status soup_selection \
               how_long_have_you_been_a_donor; do
    echo "DELETE ov FROM \`civicrm_option_value\` ov
            JOIN \`civicrm_option_group\` og ON og.id = ov.option_group_id
            WHERE og.name = '$group';"
    echo "DELETE FROM \`civicrm_option_group\` WHERE name = '$group';"
  done
  for table in civicrm_acl_cache civicrm_acl_contact_cache civicrm_group_contact_cache \
               civicrm_prevnext_cache civicrm_cache; do
    echo "TRUNCATE TABLE \`$table\`;"
  done
  echo "SET FOREIGN_KEY_CHECKS=1;"
} > "$WORK/truncate.sql"
if [[ $DRY_RUN -eq 1 ]]; then
  printf 'would run %d statements (%s)\n' "$(grep -c ';' "$WORK/truncate.sql" || true)" "$WORK/truncate.sql"
else
  "${MYSQL[@]}" < "$WORK/truncate.sql" 2>/dev/null
  printf 'done\n'
fi

# Any civicrm_value_* table whose custom group was just truncated is orphaned,
# and a group re-created later can be handed the same table name.
printf 'dropping orphaned custom value tables ... '
"${MYSQL[@]}" -N -e "SELECT CONCAT('DROP TABLE IF EXISTS \`', table_name, '\`;')
  FROM information_schema.tables
  WHERE table_schema = '$DB_NAME' AND table_name LIKE 'civicrm\\_value\\_%'
    AND table_name NOT IN (SELECT table_name FROM civicrm_custom_group);" 2>/dev/null > "$WORK/drop_values.sql"
if [[ $DRY_RUN -eq 1 ]]; then
  # Computed against the database as it stands; the real run computes it after
  # truncating civicrm_custom_group, so the real count is normally higher.
  printf 'would drop %d (measured before the truncate)\n' "$(grep -c . "$WORK/drop_values.sql" || true)"
else
  "${MYSQL[@]}" < "$WORK/drop_values.sql" 2>/dev/null
  printf '%d dropped\n' "$(grep -c . "$WORK/drop_values.sql" || true)"
fi

printf 'filtering the dump ... '
printf '%s\n' "${LOAD_TABLES[@]}" > "$WORK/load_tables.txt"
php -r '
$work = $argv[1];
$load = array_flip(array_filter(explode("\n", file_get_contents("$work/load_tables.txt"))));
$in = fopen($argv[2], "r");
$out = fopen("$work/seed.sql", "w");
$tail = FALSE; $keep = FALSE; $seen = 0;
while (($line = fgets($in)) !== FALSE) {
  // Everything from the hand-written section onwards is additive.
  if (!$tail && str_contains($line, "-- * Sample Custom Data")) { $tail = TRUE; }
  if ($tail) { fwrite($out, $line); continue; }
  if (preg_match("/^-- Dumping data for table `([a-z_0-9]+)`/", $line, $m)) {
    $keep = isset($load[$m[1]]);
    $seen++;
  }
  if ($keep) { fwrite($out, $line); }
  // The session preamble, before the first table marker.
  elseif ($seen === 0 && str_starts_with($line, "/*!")) { fwrite($out, $line); }
}
fclose($in); fclose($out);
' "$WORK" "$DUMP"
printf 'done (%s)\n' "$(du -h "$WORK/seed.sql" | cut -f1)"

if [[ $DRY_RUN -eq 1 ]]; then
  cat <<DRY

DRY RUN -- nothing was changed. A real run would now:
  load     $(du -h "$WORK/seed.sql" | cut -f1) of filtered dump into $DB_NAME
  rebuild  CiviCRM's triggers and caches
  repoint  every civicrm_uf_match row whose contact no longer exists
  rebuild  Drupal's caches

Backup taken anyway: $BACKUP
Re-run with --yes (without --dry-run) to do it.
DRY
  exit 0
fi

printf 'loading ... '
if ! "${MYSQL[@]}" < "$WORK/seed.sql" 2> "$WORK/load.err" > /dev/null; then
  printf '\n'
  grep -v '^mysql: \[Warning\]' "$WORK/load.err" >&2 || true
  die "the load failed; restore from $BACKUP"
fi
printf 'done\n'

printf 'rebuilding triggers and caches ... '
if ! "${DRUSH[@]}" ev '\Drupal::service("civicrm")->initialize();
  \Civi::service("sql_triggers")->rebuild();
  \Civi::rebuild(["*" => TRUE])->execute();' > "$WORK/rebuild.out" 2>&1; then
  printf 'failed\n'
  cat "$WORK/rebuild.out" >&2
  die "the trigger and cache rebuild failed; the load succeeded but the triggers are still dropped. Restore from $BACKUP or rerun the rebuild by hand."
fi
printf 'done\n'

printf 'repointing civicrm_uf_match ...\n'
# Every row, not just the first: a site with several Drupal users has a
# civicrm_uf_match row each, and the load replaced all of the contacts they
# pointed at. A row whose contact is still there is left alone, so this is
# safe to run twice.
if ! "${DRUSH[@]}" ev '\Drupal::service("civicrm")->initialize();
  $rows = \Civi\Api4\UFMatch::get(FALSE)->addOrderBy("id", "ASC")->execute();
  $fixed = 0; $total = 0;
  foreach ($rows as $match) {
    $total++;
    // Raw existence, and not soft-deleted: API4 Contact::get hides deleted
    // contacts by default, which would make a deleted one look absent.
    $exists = 0;
    if (!empty($match["contact_id"])) {
      $exists = (int) \CRM_Core_DAO::singleValueQuery(
        "SELECT COUNT(*) FROM civicrm_contact WHERE id = %1 AND is_deleted = 0",
        [1 => [$match["contact_id"], "Integer"]]
      );
    }
    if ($exists) { continue; }
    $account = \Drupal\user\Entity\User::load($match["uf_id"]);
    $id = \Civi\Api4\Contact::create(FALSE)
      ->addValue("contact_type", "Individual")
      ->addValue("first_name", $account ? $account->getAccountName() : "Site")
      ->addValue("last_name", "Administrator")
      ->execute()->first()["id"];
    if (!empty($match["uf_name"])) {
      \Civi\Api4\Email::create(FALSE)->addValue("contact_id", $id)
        ->addValue("email", $match["uf_name"])->addValue("location_type_id", 1)
        ->addValue("is_primary", TRUE)->execute();
    }
    \Civi\Api4\UFMatch::update(FALSE)->addWhere("id", "=", $match["id"])
      ->addValue("contact_id", $id)->execute();
    printf("  uf_match %d (uid %d) -> contact %d\n", $match["id"], $match["uf_id"], $id);
    $fixed++;
  }
  printf("  %d of %d uf_match rows repointed\n", $fixed, $total);' > "$WORK/repoint.out" 2>&1; then
  printf '  failed\n'
  cat "$WORK/repoint.out" >&2
  printf '  warning: the Drupal users have no CiviCRM contact; the data itself is loaded\n' >&2
else
  cat "$WORK/repoint.out"
fi

"${DRUSH[@]}" cache:rebuild >/dev/null 2>&1

cat <<NEXT

Sample data loaded. Backup: $BACKUP

Next:
  ${DRUSH[*]} php:script web/modules/contrib/civicrm_entity/tests/fixtures/seed-civicrm-fixture.php
  ${DRUSH[*]} civicrm-entity:parity --limit=25 --writes --custom-values
NEXT
