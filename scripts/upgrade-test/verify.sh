#!/usr/bin/env bash
#
# Record one checkpoint of the target site and compare it with the previous one.
#
#   ./verify.sh <checkpoint> [--http] [--no-snapshot] [--prev=<name>] [--set=DIR]
#
#   --http           also run the HTTP smoke pass over the set's page views
#   --no-snapshot    do not take a database checkpoint afterwards
#   --prev=<name>    compare against $RUN/<name>.json instead of the newest
#                    checkpoint JSON in $RUN
#   --set=DIR        config set root the page paths come from (default $SET/api3)
#
# Five stages, each independent:
#   1. $HARNESS/checkpoint.php writes $RUN/<checkpoint>.json, counting rows and
#      configuration and draining the watchdog since the previous checkpoint's
#      meta.max_wid so each checkpoint owns only the log entries it caused;
#   2. civicrm-entity:api-audit, when the site's module is new enough to have
#      the command, to $RUN/<checkpoint>-audit.json;
#   3. the HTTP smoke pass -- log in once, request every page display of every
#      views.view.ce_*.yml in the set, and count the two failure strings a
#      broken views handler produces;
#   4. compare.php against the previous checkpoint, with the allowlist at
#      $SET/expected-diffs/<checkpoint>.json when there is one;
#   5. snapshot.sh <checkpoint> --force.
#
# No stage aborts the run. Each records an exit code and the script ends with
#   verify <checkpoint>: checkpoint=<rc> audit=<rc> http=<rc> compare=<rc>
# which is also appended to $RUN/verify-summary.txt for run-all.sh to collect.
# An rc of `-` means the stage was skipped.

set -euo pipefail

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/upgrade-test/env.sh
source "$_HERE/env.sh"

CP=''
WANT_HTTP=0
WANT_SNAPSHOT=1
PREV_NAME=''
SET_ROOT="$SET/api3"

for arg in "$@"; do
  case "$arg" in
    --http) WANT_HTTP=1 ;;
    --no-snapshot) WANT_SNAPSHOT=0 ;;
    --prev=*) PREV_NAME="${arg#--prev=}" ;;
    --set=*) SET_ROOT="${arg#--set=}" ;;
    -*) die "unknown option: $arg" ;;
    *) [[ -z "$CP" ]] || die "one checkpoint name at a time (got '$CP' and '$arg')"; CP="$arg" ;;
  esac
done
[[ -n "$CP" ]] || die "usage: verify.sh <checkpoint> [--http] [--no-snapshot] [--prev=<name>] [--set=DIR]"

step "verify $CP"

RC_CHECKPOINT='-'
RC_AUDIT='-'
RC_HTTP='-'
RC_COMPARE='-'

# --- which checkpoint are we comparing against ------------------------------
# Resolved before the new JSON is written, so `newest in $RUN` means the one
# before this rather than this one.
if [[ -n "$PREV_NAME" ]]; then
  PREV_JSON="$RUN/$PREV_NAME.json"
else
  PREV_JSON="$(latest_checkpoint_json)"
  # A resumed run (run-all.sh --from=<checkpoint>) starts with an empty $RUN;
  # its baseline is the checkpoint it restored, recorded by an earlier run.
  if [[ -z "$PREV_JSON" && -n "${RESUMED_FROM:-}" ]]; then
    PREV_JSON="$RUN/$RESUMED_FROM.json"
  fi
fi
if [[ -n "$PREV_JSON" && ! -f "$PREV_JSON" ]]; then
  # A run resumed with --from=<checkpoint> restores a checkpoint an earlier run
  # recorded; its JSON lives in that run's directory. Use the newest copy so
  # the first comparison of the resumed run still has its baseline.
  _candidate="$(ls -t "$PROTO"/scripts/upgrade-test/out/*/"$(basename "$PREV_JSON")" 2>/dev/null | head -n 1 || true)"
  if [[ -n "$_candidate" && -f "$_candidate" ]]; then
    log "  previous checkpoint taken from an earlier run: $_candidate"
    PREV_JSON="$_candidate"
  else
    log "  no previous checkpoint at $PREV_JSON; this is the baseline"
    PREV_JSON=''
  fi
fi

SINCE=0
if [[ -n "$PREV_JSON" ]]; then
  SINCE="$(json_get "$PREV_JSON" meta.max_wid)"
  [[ -n "$SINCE" ]] || SINCE=0
  log "  comparing against $(basename "$PREV_JSON") (watchdog since wid $SINCE)"
fi

# --- 1. the checkpoint ------------------------------------------------------
CP_JSON="$RUN/$CP.json"
CP_LOG="$RUN/$CP-checkpoint.log"
: > "$CP_LOG"
if [[ -f "$HARNESS/checkpoint.php" || "$DRY_RUN" == "1" ]]; then
  RC_CHECKPOINT=0
  run_tee "$CP_LOG" "${DRUSH[@]}" php:script "$HARNESS/checkpoint.php" -- "$CP" "$CP_JSON" "--since-wid=$SINCE" \
    || RC_CHECKPOINT=$?
else
  log "  warning: $HARNESS/checkpoint.php is missing; skipping the checkpoint stage"
fi

# --- 2. the API routing audit ----------------------------------------------
if drush_has_command 'civicrm-entity:api-audit'; then
  RC_AUDIT=0
  run_capture "$RUN/$CP-audit.json" "${DRUSH[@]}" civicrm-entity:api-audit --format=json || RC_AUDIT=$?
else
  log "  civicrm-entity:api-audit is not available on this module version; skipping the audit"
fi

# --- 3. the HTTP smoke pass -------------------------------------------------
# Reads every page display path out of the set's ce_* views and requests it as
# an authenticated user. `Broken/missing handler` is what views renders when a
# field or filter plugin no longer resolves, which is exactly the damage an
# api_backend switch does; the unexpected-error string catches a WSOD.
read -r -d '' VIEW_PATHS_PHP <<'PHP' || true
require $argv[1];
foreach (array_slice($argv, 2) as $file) {
  $data = \Symfony\Component\Yaml\Yaml::parseFile($file);
  if (!is_array($data)) { continue; }
  foreach (($data['display'] ?? []) as $display) {
    if (($display['display_plugin'] ?? '') !== 'page') { continue; }
    $path = $display['display_options']['path'] ?? NULL;
    if (is_string($path) && $path !== '') { echo $path, "\n"; }
  }
}
PHP

http_smoke() {
  local tsv="$RUN/$CP-http.tsv"
  local report="$RUN/$CP-status-report.txt"
  local cookies="$RUN/cookies.txt"

  run "${DRUSH[@]}" sset system.maintenance_mode 0

  if [[ "$DRY_RUN" == "1" ]]; then
    log "  + LINK=\$(${DRUSH[*]} uli --no-browser --uri=$URI | tail -1)"
    log "  + curl -s -c $cookies -L \"\$LINK\" -o /dev/null"
    log "  + for each page path in $SET_ROOT/{portable,site}/views.view.ce_*.yml: curl $URI/<path> >> $tsv"
    log "  + curl $URI/admin/reports/status | grep -i -A3 'civicrm entity' > $report"
    return 0
  fi

  local files=()
  local dir
  for dir in "$SET_ROOT/portable" "$SET_ROOT/site"; do
    [[ -d "$dir" ]] || continue
    while IFS= read -r f; do files+=("$f"); done < <(find "$dir" -maxdepth 1 -type f -name 'views.view.ce_*.yml' | sort)
  done
  if [[ ${#files[@]} -eq 0 ]]; then
    log "  no views.view.ce_*.yml under $SET_ROOT; nothing to request"
    : > "$tsv"
    return 0
  fi

  # uid 1 is blocked on some sites (it is on the D11 test site); a one-time
  # login link for a blocked account is refused, so unblock it first.
  # By SQL, not the entity API: saving the account fires a status-change mail,
  # and the D11 site's mail plugin throws, which rolls the save back.
  run "${DRUSH[@]}" sql:query "UPDATE users_field_data SET status = 1 WHERE uid = 1" >/dev/null 2>&1 || true
  run "${DRUSH[@]}" php:eval '\Drupal::entityTypeManager()->getStorage("user")->resetCache([1]);' >/dev/null 2>&1 || true
  local link
  link="$("${DRUSH[@]}" uli --no-browser --uid=1 "--uri=$URI" 2>/dev/null | grep -Eo 'https?://[^[:space:]]+' | tail -1)" || link=''
  if [[ -z "$link" ]]; then
    log "  could not get a one-time login link; the smoke pass would only see anonymous pages"
    return 1
  fi
  rm -f "$cookies"
  curl -s -c "$cookies" -L "$link" -o /dev/null || log "  warning: the login request failed"

  local paths=()
  while IFS= read -r p; do
    [[ -n "$p" ]] && paths+=("$p")
  done < <(php -r "$VIEW_PATHS_PHP" "$SITE/vendor/autoload.php" "${files[@]}" 2>/dev/null | sort -u)

  printf 'path\tstatus\tbroken_count\tunexpected_error_count\tbytes\n' > "$tsv"
  local body status broken unexpected bytes request
  body="$(mktemp)"
  local rc=0
  for p in "${paths[@]}"; do
    # Views argument placeholders are whole path segments; 1 is the first
    # contact/activity/... on every fixture, so it renders something.
    request="${p//%/1}"
    status="$(curl -s -b "$cookies" -c "$cookies" -L -o "$body" -w '%{http_code}' "$URI/${request#/}" || echo 000)"
    broken="$(grep -c 'Broken/missing handler' "$body" || true)"
    unexpected="$(grep -c 'The website encountered an unexpected error' "$body" || true)"
    bytes="$(wc -c < "$body")"
    printf '%s\t%s\t%s\t%s\t%s\n' "$request" "$status" "$broken" "$unexpected" "$bytes" >> "$tsv"
    if [[ "$status" != "200" || "$broken" != "0" || "$unexpected" != "0" ]]; then
      rc=1
    fi
  done

  curl -s -b "$cookies" -c "$cookies" -L -o "$body" "$URI/admin/reports/status" || true
  sed 's/<[^>]*>/ /g' "$body" | grep -i -A3 'civicrm entity' > "$report" || : > "$report"
  rm -f "$body"

  log "  $(( ${#paths[@]} )) page path(s) requested; $tsv"
  return "$rc"
}

if [[ $WANT_HTTP -eq 1 && "$HTTP_SMOKE" == "1" ]]; then
  RC_HTTP=0
  http_smoke || RC_HTTP=$?
elif [[ $WANT_HTTP -eq 1 ]]; then
  log "  HTTP_SMOKE=0; skipping the HTTP pass even though --http was given"
fi

# --- 4. the comparison ------------------------------------------------------
if [[ -n "$PREV_JSON" && -f "$HARNESS/compare.php" ]]; then
  COMPARE_ARGS=("$HARNESS/compare.php" "$PREV_JSON" "$CP_JSON" --no-fail)
  ALLOW="$SET/expected-diffs/$CP.json"
  if [[ -f "$ALLOW" ]]; then
    COMPARE_ARGS+=("--allow=$ALLOW")
    log "  using the allowlist at $ALLOW"
  fi
  : > "$RUN/$CP-compare.txt"
  RC_COMPARE=0
  run_tee "$RUN/$CP-compare.txt" php "${COMPARE_ARGS[@]}" || RC_COMPARE=$?
elif [[ -n "$PREV_JSON" ]]; then
  if [[ "$DRY_RUN" == "1" ]]; then
    log "  + php $HARNESS/compare.php $PREV_JSON $CP_JSON --no-fail  (compare.php not written yet)"
  else
    log "  warning: $HARNESS/compare.php is missing; skipping the comparison"
  fi
fi

# --- 5. the snapshot --------------------------------------------------------
if [[ $WANT_SNAPSHOT -eq 1 ]]; then
  if ! run_script "$_HERE/snapshot.sh" "$CP" --force; then
    log "  warning: snapshot $CP failed; the run can continue but cannot be resumed from here"
  fi
fi

SUMMARY="verify $CP: checkpoint=$RC_CHECKPOINT audit=$RC_AUDIT http=$RC_HTTP compare=$RC_COMPARE"
printf '%s\n' "$SUMMARY" | tee -a "$RUN/verify-summary.txt" >&2
