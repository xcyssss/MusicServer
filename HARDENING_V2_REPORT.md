# MusicServer Hardening v2 Phase 5 Validation Report

## Environment

- Branch: `review/musicserver-hardening-v2`
- Phase 5 base SHA: `09f798e2755ef70d31e2ba2486339ac2950dce35`
- Phase 5 checkpoint SHA: provided in the final handoff after commit
- PowerShell 7: local validation
- Windows PowerShell 5.1: local validation
- SQLite: repository-resolved `sqlite3.exe`
- Test data: fresh scratch roots and scratch databases; production state is read-only audited only

## Phase 5 Legacy Runtime Retirement

The Worker and Cleanup runtime paths now use SQLite as their authoritative
state source. Queue enumeration, claim, lease renewal, cancellation, retry,
canonical status, provider health, and events no longer read legacy JSON/CSV.
Cleanup reads recommendation file metadata and feedback from SQLite. Legacy
JSON/CSV files remain only as migration inputs, backups, or compatibility
exports; they cannot override a committed SQLite decision.

The four authority-conflict cases pass: SQLite CANCEL_REQUESTED overrides a
legacy RESOLVING row, SQLite REMOTE prevents a legacy WANTED row from causing a
download, SQLite WANTED is claimable with missing legacy JSON, and SQLite
UNAVAILABLE prevents a legacy RETRY_WAIT from causing a retry.

Migration now reports `SAFE_IDEMPOTENT`, `EXPECTED_LEGACY_OVERLAP`,
`STALE_LEGACY`, `IDENTITY_AMBIGUITY`, `SEMANTIC_CONFLICT`, and `MALFORMED`
categories, including skipped-row classification. A rehearsal against a copy
of the production SQLite snapshot returned `SUCCESS` on the first run and
`ALREADY_MIGRATED` with `idempotent=True` on the second run. The production
files were not modified.

## Recommendation SQLite Migration

`daily_recommend.ps1` now initializes the SQLite schema and uses State-layer
helpers for seed selection, accepted/rejected exclusions, cooldown, canonical
metadata, daily recommendation rows, and DISPLAY feedback. It does not call
download, provider, ffprobe, or lyrics-download code.

Only an explicit `daily_recommend.ps1 -MigrateLegacy` run may perform the
one-time legacy import. A committed `recommendation_state_v2` migration marker
prevents subsequent runs from rereading legacy files. Normal scheduled runs
and DryRun do not trigger migration; DryRun requires an existing SQLite
database and does not initialize or upgrade the target database.

## Feedback Semantics

| Signal | Weight | Runtime source |
|---|---:|---|
| explicit_like | 5 | SQLite `LIKE` feedback, unless the latest explicit fact is `UNLIKE` |
| accepted | 4 | SQLite `ACCEPTED` feedback imported from `accepted.csv` once |
| navidrome_star | 5 | dynamic Navidrome star snapshot, plus SQLite snapshot facts |
| local/library fallback | 1 | SQLite `LIBRARY_FALLBACK` feedback imported from `lyrics_report.csv` |
| DISPLAY / neutral history | 0 | SQLite display/history only; never a seed |

LIKE values accept `true`, `1`, and `yes`; a string `False` is not positive.
Independent facts are retained, with the strongest positive signal exposed to
seed selection. A later explicit UNLIKE revokes an earlier explicit LIKE.

## Cooldown

- Storage: SQLite `daily_recommendations`
- Identity: `track_id` and `netease_id` are returned to the runtime filter
- Window: inclusive `as_of_date - 14 days` through `as_of_date`
- Boundary: the 14-day boundary remains excluded from new recommendations,
  matching the existing `date >= today - 14 days` behavior
- Future rows: ignored (`date <= as_of_date`) as a bad-timestamp safeguard
- Duplicate rows: SQL `DISTINCT` and deterministic daily replacement prevent
  duplicate impact

## Daily Recommendation Transaction

`Save-DailyRecommendationsDb` uses one `BEGIN IMMEDIATE` SQLite transaction to
replace the complete day, upsert canonical metadata without overwriting active
worker status/revision, insert ranked rows, and insert deterministic DISPLAY
feedback. Duplicate/invalid ranks are rejected before any write. Repeating a
day replaces the complete set atomically and leaves one row per rank and one
DISPLAY row per generated recommendation key. Failure injection rolls back the
old complete set rather than leaving a partial day.

## JSON Runtime Retirement

The deliberate conflict tests cover:

1. SQLite LIKE vs. contradictory legacy history: seed selection uses SQLite.
2. SQLite DISPLAY vs. missing legacy history: cooldown uses SQLite.
3. SQLite recommendation C vs. legacy recommendation D: API recommendation
   reads use SQLite.

`daily_recommend.ps1` has no legacy recommendation JSON/CSV reads. The Phase 5
Worker and Cleanup retirement is recorded in the audit below.

## Migration

Migration covers canonical tracks, daily recommendation rows, display history,
legacy explicit likes, accepted rows, rejected rows, library fallback rows,
wanted items, provider health, and legacy events. It is non-destructive, uses a
transaction, reports malformed/ignored rows and daily/provider conflicts,
preserves existing SQLite daily/provider state, creates a timestamped backup,
and is idempotent through a SQLite marker. Legacy source files are not deleted.

## Compatibility

Worker CAS/lease semantics remain intact. The Worker and Cleanup now use
SQLite-authoritative runtime reads; JSON/CSV outputs are compatibility artifacts
only. The recommendation generator, API, Worker, and Cleanup are all
SQLite-authoritative for the migrated state surfaces.

## Tests

The complete local regression and integration runs are green:

| Suite / check | PowerShell 7 | PowerShell 5.1 |
|---|---:|---:|
| Core | 24/24 | 24/24 |
| Database | 5/5 | 5/5 |
| V2 | 31/31 | 31/31 |
| WorkerConcurrency | 4/4 | 4/4 |
| LegacyRetirement | 9/9 | 9/9 |
| ApiTransaction | 17/17 | 17/17 |
| ApiRuntime | 5/5 | not required |
| Recommendation | 38/38 | 38/38 |
| Web | 2/2 | not required |

PS7 state-group total: 113/113 (Core, Database, V2, WorkerConcurrency,
Recommendation, LegacyRetirement, Web). PS7 API total: 22/22
(ApiTransaction, ApiRuntime). PS5.1 state-group total: 111/111 (Web is
excluded because it contains live-runtime tests); PS5.1 API total: 22/22.

Reproducible validation command record (run from the repository root):

```powershell
# PS7 state group: Core, Database, V2, WorkerConcurrency, Recommendation, LegacyRetirement, Web
pwsh -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Pester -RequiredVersion 3.4.0 -Force; `$files=@('.\\tests\\MusicServer.Core.Tests.ps1','.\\tests\\MusicServer.Database.Tests.ps1','.\\tests\\MusicServer.V2.Tests.ps1','.\\tests\\MusicServer.WorkerConcurrency.Tests.ps1','.\\tests\\MusicServer.Recommendation.Tests.ps1','.\\tests\\MusicServer.LegacyRetirement.Tests.ps1','.\\tests\\MusicServer.Web.Tests.ps1'); `$total=0; `$passed=0; `$failed=0; foreach(`$file in `$files){ `$r=if(`$file -like '*Web*'){Invoke-Pester `$file -PassThru -ExcludeTag RequiresLocalRuntime}else{Invoke-Pester `$file -PassThru}; `$total += `$r.TotalCount; `$passed += `$r.PassedCount; `$failed += `$r.FailedCount }; \"PS7 state TOTAL=`$total PASSED=`$passed FAILED=`$failed\""

# PS7 API group
pwsh -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Pester -RequiredVersion 3.4.0 -Force; `$total=0; `$passed=0; `$failed=0; foreach(`$file in @('.\\tests\\MusicServer.ApiTransaction.Tests.ps1','.\\tests\\MusicServer.ApiRuntime.Tests.ps1')){ `$r=Invoke-Pester `$file -PassThru; `$total += `$r.TotalCount; `$passed += `$r.PassedCount; `$failed += `$r.FailedCount }; \"PS7 API TOTAL=`$total PASSED=`$passed FAILED=`$failed\""

# Windows PowerShell 5.1 state group without live-runtime Web tests
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Pester -RequiredVersion 3.4.0 -Force; `$files=@('.\\tests\\MusicServer.Core.Tests.ps1','.\\tests\\MusicServer.Database.Tests.ps1','.\\tests\\MusicServer.V2.Tests.ps1','.\\tests\\MusicServer.WorkerConcurrency.Tests.ps1','.\\tests\\MusicServer.Recommendation.Tests.ps1','.\\tests\\MusicServer.LegacyRetirement.Tests.ps1'); `$total=0; `$passed=0; `$failed=0; foreach(`$file in `$files){ `$r=Invoke-Pester `$file -PassThru; `$total += `$r.TotalCount; `$passed += `$r.PassedCount; `$failed += `$r.FailedCount }; \"PS5.1 state TOTAL=`$total PASSED=`$passed FAILED=`$failed\""

# Windows PowerShell 5.1 API group
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Pester -RequiredVersion 3.4.0 -Force; `$total=0; `$passed=0; `$failed=0; foreach(`$file in @('.\\tests\\MusicServer.ApiTransaction.Tests.ps1','.\\tests\\MusicServer.ApiRuntime.Tests.ps1')){ `$r=Invoke-Pester `$file -PassThru; `$total += `$r.TotalCount; `$passed += `$r.PassedCount; `$failed += `$r.FailedCount }; \"PS5.1 API TOTAL=`$total PASSED=`$passed FAILED=`$failed\""
```

Captured totals: PS7 state `TOTAL=113 PASSED=113 FAILED=0`, PS7 API
`TOTAL=22 PASSED=22 FAILED=0`, PS5.1 state `TOTAL=111 PASSED=111 FAILED=0`,
and PS5.1 API `TOTAL=22 PASSED=22 FAILED=0`. The same validation run
included the real scratch HTTP API integration, a zero-count recommendation
DryRun with an unchanged database hash, and the production
`Invoke-MusicServerMigration -DryRun` read-only audit.

## API Integration

Scratch HTTP integration result: PASS. The Recommendation suite generated a
SQLite daily set, served it through the real API, confirmed rank/metadata,
posted LIKE, observed SQLite explicit_like and WANTED, deleted the LIKE, and
confirmed REMOTE with no wanted row. The ApiTransaction/ApiRuntime suites also
cover the active-lease cancellation and server-restart paths. API startup does
not import `MusicServer.Migration.psm1`, create a migration marker, or rewrite
legacy recommendation files.

## Recommendation Feedback E2E

Scratch HTTP LIKE → SQLite explicit_like → State-layer next-seed read: PASS.
The actual external NetEase candidate fetch is intentionally not part of the
deterministic test; a real scratch `daily_recommend.ps1 -DryRun` with zero
seeds also passed and made no recommendation-state write.

## Cooldown E2E

Scratch DISPLAY → SQLite daily history → next cooldown exclusion: PASS in the
Recommendation suite, including the 14-day boundary, future dates, and
duplicate display handling.

## Runtime JSON Dependency Audit

Authoritative Worker, Cleanup, recommendation, and API JSON/CSV reads: 0 for
runtime state decisions. Remaining reads are migration or compatibility helper
surfaces and the provider HTTP response parser. See
`RUNTIME_JSON_DEPENDENCY_AUDIT.md` for the exact inventory.

## Worker/Cleanup Compatibility Mirror

- read: no legacy runtime-state reads
- write: compatibility JSON/CSV exports remain where existing callers need them
- authoritative: SQLite owns queue, canonical, feedback, provider, and event state
- conflict behavior: contradictory legacy rows are ignored; the four authority
  conflict cases are covered by `MusicServer.LegacyRetirement.Tests.ps1`

## Performance

20-iteration scratch smoke (milliseconds): seed median 160.1 / p95 181.0;
cooldown median 80.1 / p95 89.0; recommendation read median 87.2 / p95 98.4.
The State queries are indexed on daily date and feedback track; the complete-
day write is one SQLite process.

## Production Dry Run

Production database was observed pre-activation: `user_version=0`, no
`migration_markers` table, 81 canonical tracks, 81 daily rows, 0 feedback
rows, 2 wanted rows, 1 provider row, and 1 event row. Daily rows are dated
2026-08-25 (1) through 2026-08-29 (20 each). Legacy files contain 101 tracks,
20 recommendations, 101 history rows, 40 event lines, 5 accepted rows, 140
rejected rows, 164 lyrics-report rows, 2 wanted rows, and 2 provider rows.

Read-only `Invoke-MusicServerMigration -DryRun` reported source counts of
tracks=101, recommendations=20, history=101, events=40, accepted=5,
rejected=140, lyrics_report=164, wanted=2, and providers=2. Its preview
reported imports of tracks=20, recommendations=20, history=0, events=40,
accepted=5, rejected=140, lyrics_fallback=140, wanted=0, providers=0,
display=20, explicit_likes=2, skipped=85, and conflicts=186. The existing DB
counts were canonical=81, daily=81, feedback=0, wanted=2, provider=1, and
events=1. `legacy_ignored` recorded 24 invalid lyrics rows and one legacy
`bilibili` provider. It created no backup and performed no writes; the
conflict report retained existing SQLite daily/provider state. Conflict
categories were `SAFE_IDEMPOTENT=162`, `EXPECTED_LEGACY_OVERLAP=20`,
`STALE_LEGACY=4`, `IDENTITY_AMBIGUITY=0`, `SEMANTIC_CONFLICT=0`, and
`MALFORMED=0`. The 85 merge skips were classified as
`SAFE_IDEMPOTENT=81` and `STALE_LEGACY=4`; the 24 malformed rows were
reported separately as `MALFORMED`.
No production DB write, runtime activation, JSON deletion, music deletion, or
Navidrome DB modification was performed.

## Bugs Found

- `CODE_BUG`: marker-only migration initially changed the existing Phase 3
  idempotency contract for a populated DB with no legacy input; the
  pre-marker/no-input compatibility path was restored and ApiTransaction is
  17/17.
- `COMPATIBILITY_BUG`: newly written PowerShell files require UTF-8 BOM for
  Windows PowerShell 5.1 to parse non-ASCII fixtures correctly; fixed in the
  Phase 4/5 files.
- `LEGACY_STATE_ISSUE`: Phase 4 identified Worker/Cleanup legacy runtime reads;
  Phase 5 removed those reads from the runtime decision paths and retained only
  migration/compatibility surfaces.

## Changes Made

- Phase 4 implementation checkpoint: `d40d2c17fcea77824ad609215f1d760b05ce3bf4`
  (`Integrate SQLite recommendation state`)
- Correctness follow-up checkpoint: `8b87799649408db5953058d511b9e0e03e0e0cfb`
  (`Harden recommendation migration boundaries`)
- Phase 5 checkpoint: this report is included in
  `Retire legacy runtime state reads and harden migration`.
- Phase 5 source/test/docs files: `.github/workflows/core-tests.yml`,
  `MusicServer.Migration.psm1`, `MusicServer.Providers.psm1`,
  `MusicServer.State.psm1`, `daily_cleanup.ps1`, `wanted_worker.ps1`,
  `tests/MusicServer.LegacyRetirement.Tests.ps1`,
  `HARDENING_V2_REPORT.md`, `RUNTIME_JSON_DEPENDENCY_AUDIT.md`
- Untouched untracked files: `MusicServer.DesiredStateWorker.psm1`,
  `start_musicserver.ps1`, `stop_musicserver.ps1`

## Remaining Risks

- Compatibility JSON/CSV exports remain by design; they are not runtime state
  inputs and should be removed only in a separately authorized cleanup.
- Production migration activation remains intentionally pending.
- Real successful Bilibili download E2E remains external/provider dependent and
  is still affected by HTTP 412/rate-limit conditions.

## Final Verdict

PASS_WITH_WARNINGS — Phase 5 legacy runtime-read retirement and migration
hardening are complete with all scoped checks green. SQLite is authoritative
for the migrated runtime state; compatibility files remain as exports and
migration inputs. Production migration activation and successful Bilibili
download E2E remain intentionally pending.
No legacy JSON deletion or main merge was performed.

Answers to the Phase 5 acceptance questions:

1. Phase 5: COMPLETE; Worker, Cleanup, API, and recommendation runtime state
   decisions are SQLite-authoritative.
2. Runtime state authority: SQLite; JSON/CSV remain compatibility/migration
   artifacts only.
3. Neutral recommendation history as seed: no longer used.
4. 14-day cooldown: SQLite-authoritative for the recommender.
5. accepted.csv and recommendation JSON: migration input only after activation,
   not runtime decision sources for this path.
6. Runtime authoritative JSON/CSV reads remain: none in the migrated paths;
   Core compatibility and migration readers remain intentionally available.
7. Worker/Cleanup JSON mirror: write-only compatibility behavior remains where
   needed; it cannot override SQLite.
8. Production migration activation: ready for a separately authorized change,
   but not activated here.
9. Full v2 E2E: metadata/state/API E2E is green; successful Bilibili download
   E2E remains provider-dependent and deferred.
10. v2 PR: not created automatically; review branch remains unmerged.
