# civicrm_entity upgrade test — orchestration

Scripts that upgrade a Drupal 11 site from civicrm_entity 4.0.8 to the 5.0.x
working tree in this repository and move it through the API backends, taking a
restorable checkpoint after every step. The methodology, the checkpoint table
and the findings live in `docs/upgrade-test-d11-4x-to-5x.md`; this file is the
operator's reference for the scripts themselves.

Everything is parameterised through `env.sh`:

| Variable | Default | Meaning |
| --- | --- | --- |
| `SITE` | `/var/www/web/distro11-upsun` | the target site root |
| `URI` | `http://distro11.upsun.me` | passed to every drush call as `-l` (the civicrm module's update check refuses `http://default`) |
| `BACKUPS` | `~/db-backups/ce-upgrade-test` | checkpoint store: `<name>/{drupal,civicrm}.sql.gz`, `module-version`, `taken-at`, plus `module-4.0.8.tar.gz` |
| `RUN_ID` | `YYYYmmdd-HHMM` | run directory `scripts/upgrade-test/out/<RUN_ID>/` |
| `DRY_RUN` | `0` | `1` echoes every state-changing command instead of running it; read-only lookups still run |
| `SIMULATE_MISSING_TYPES` | `0` | `1` uninstalls the two Pledge entity-type definitions right before `updb` (synthetic; see `upgrade.sh`) |
| `HTTP_SMOKE` | `1` | `0` suppresses the HTTP pass even when `--http` is given |
| `STOP_AFTER` | | `run-all.sh` stops once the step producing this checkpoint is done |

Database credentials come from the site's own `.env` (`DATABASE_HOST`,
`DATABASE_PORT`, `DATABASE_USER`, `DATABASE_PASSWORD`, `DRUPAL_DATABASE`,
`CIVICRM_DATABASE`). `env.sh` refuses to run when the site does not bootstrap or
when `config_readonly` is on.

## The scripts

| Script | Does |
| --- | --- |
| `run-all.sh [--from=<checkpoint>]` | The whole sequence; `--from` restores that checkpoint (both databases and the matching module code) and continues from the step after it. Writes `out/<RUN_ID>/SUMMARY.txt`. |
| `snapshot.sh <name> [--force]` | Dumps both databases and records the module version. Archives the 4.0.8 module tree the first time it sees it. |
| `restore.sh <name>` | Drops and reloads both databases, restores the module code the checkpoint was taken with, `cv flush`, `drush cr`. |
| `sync-module.sh 4.0.8\|5.0.x` | Swaps the module directory: untars the archived 4.0.8, or rsyncs this repository's working tree (without `.git`). Always followed by `drush cr`, because a stale container can fatal after a code swap. |
| `seed.sh` | Enables CiviCase and CiviCampaign, loads CiviCRM's generated sample data with `scripts/load-civicrm-sample-data.sh --root=$SITE --database=$CIVICRM_DATABASE`, runs the module's `tests/fixtures/seed-civicrm-fixture.php`. |
| `generate-config.sh` | Enables the contrib dependencies, exposes every entity type, runs the config-set generator (4.0.8 only) and exports the set to `tests/fixtures/config-set/api3`. |
| `import-config-set.sh [--set=DIR] [--site]` | The reusable import path: dependencies, `apply-settings.php`, `drush cr`, `config:import --partial` of `portable/` (and `site/`), `drush cr`. On a 5.0.x module it also enables the split submodules. |
| `verify.sh <checkpoint> [--http] [--no-snapshot] [--prev=<name>] [--set=DIR]` | Runs the harness checkpoint, the API audit when the command exists, the optional HTTP smoke pass, the comparison against the previous checkpoint (with `expected-diffs/<checkpoint>.json` as allowlist when present), then snapshots. Appends one summary line to `out/<RUN_ID>/verify-summary.txt`. |
| `upgrade.sh` | `sync-module.sh 5.0.x`, optional synthetic uninstall, `drush updb -y` (logged), checkpoint `28-updb-only`, enable `civicrm_entity_bundles civicrm_entity_rules civicrm_entity_search_api civicrm_entity_vbo`, checkpoint `30-upgraded-api3`. |
| `switch-mode.sh <from> <to> <checkpoint>` | `config-rewrite` plan (`--force`, JSON), `cset api_backend`, `api-audit` **before** `drush cr` (the rebuild erases `field_type_drift`), `drush cr`, `config-rewrite --apply` (JSON), `drush cr`, export the rewritten set to `tests/fixtures/config-set/expected/<from>-to-<to>`, `parity --modes=<from>,<to>` (JSON), checkpoint with HTTP. |

## Checkpoints

```
00-pristine  10-seeded  20-configured-4.0.8  20b-reimported
28-updb-only  30-upgraded-api3  40-auto  50-api4_native  60-reverse-api3  70-pledge-enabled
```

`20b-reimported` is not snapshotted: it restores `20-configured-4.0.8`, imports
the exported set through `import-config-set.sh --site` and compares against `20`
to prove the import path reproduces the generated state.

## Run artefacts (`out/<RUN_ID>/`)

`<checkpoint>.json` (harness), `<checkpoint>-checkpoint.log`,
`<checkpoint>-audit.json`, `<checkpoint>-http.tsv`, `<checkpoint>-status-report.txt`,
`<checkpoint>-compare.txt`, `<checkpoint>-plan.json` / `-audit-before-cr.json` /
`-apply.json` / `-parity.json` (mode switches), `updb.log`,
`enable-submodules.log`, `seed.log`, `60-reverse-diff.txt`, `verify-summary.txt`,
`SUMMARY.txt`. The directory is git-ignored.

## Rules of the road

- **Nobody runs Composer on the target site during a run.** `composer install`
  puts 4.0.8 back underneath a 5.0.x database. The module is swapped at file
  level only.
- Dry-run first: `DRY_RUN=1 RUN_ID=dryrun ./run-all.sh` prints the whole
  expanded command sequence and changes nothing.
- Re-entry: `./run-all.sh --from=40-auto` restores `40-auto` and continues with
  the `api4_native` step. Use `STOP_AFTER=30-upgraded-api3` to stop early.
- A failing stage never aborts the run; its exit code is in the verify summary
  line and the stage's log. Read `SUMMARY.txt` first, then the `-compare.txt`
  of the checkpoint that changed.
