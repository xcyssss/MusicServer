# MusicServer Hardening v2 Phase 4 Validation Report

## Environment

- Branch: `review/musicserver-hardening-v2`
- Base SHA: `fbfd5b5a2fdfe9770e109735df7f078a6b1f79f9`
- Final SHA: recorded in the final handoff after the checkpoint commit
- PowerShell 7: local validation
- Windows PowerShell 5.1: local validation
- SQLite: repository-resolved `sqlite3.exe`
- Test data: fresh scratch roots and scratch databases; production state is read-only audited only

## Recommendation SQLite Migration

`daily_recommend.ps1` now initializes the SQLite schema and uses State-layer
helpers for seed selection, accepted/rejected exclusions, cooldown, canonical
metadata, daily recommendation rows, and DISPLAY feedback. It does not call
download, provider, ffprobe, or lyrics-download code.

Only an explicit `daily_recommend.ps1 -MigrateLegacy` run may perform the
one-time legacy import. A committed `recommendation_state_v2` migration marker
prevents subsequent runs from rereading legacy files. Normal scheduled runs
and DryRun do not trigger migration.

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

`daily_recommend.ps1` has no legacy recommendation JSON/CSV reads. See
`RUNTIME_JSON_DEPENDENCY_AUDIT.md` for the remaining project-wide worker and
cleanup dependencies.

## Migration

Migration covers canonical tracks, daily recommendation rows, display history,
legacy explicit likes, accepted rows, rejected rows, library fallback rows,
wanted items, provider health, and legacy events. It is non-destructive, uses a
transaction, reports malformed/ignored rows, preserves conflicts, creates a
timestamped backup, and is idempotent through a SQLite marker. Legacy source
files are not deleted.

## Compatibility

Worker CAS/lease semantics were not changed in Phase 4. The worker's SQLite
claim authority remains intact, but its legacy JSON reads and compatibility
writes remain a Phase 5 follow-up. The recommendation generator and API are
SQLite-authoritative within this phase.

## Tests

The complete local regression and integration runs are green:

| Suite / check | PowerShell 7 | PowerShell 5.1 |
|---|---:|---:|
| Core | 24/24 | 24/24 |
| Database | 5/5 | 5/5 |
| V2 | 31/31 | 31/31 |
| WorkerConcurrency | 4/4 | 4/4 |
| ApiTransaction | 17/17 | 17/17 |
| ApiRuntime | 5/5 | not required |
| Recommendation | 33/33 | 33/33 |
| Web | 2/2 | not required |

PS7 state-group total: 99/99 (Core, Database, V2, WorkerConcurrency,
Recommendation, Web). PS7 API total: 22/22 (ApiTransaction, ApiRuntime).
PS5.1 required Phase 4 total: 114/114.

## API Integration

Scratch HTTP integration result: PASS. The Recommendation suite generated a
SQLite daily set, served it through the real API, confirmed rank/metadata,
posted LIKE, observed SQLite explicit_like and WANTED, deleted the LIKE, and
confirmed REMOTE with no wanted row. The ApiTransaction/ApiRuntime suites also
cover the active-lease cancellation and server-restart paths.

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

Recommendation generator and API authoritative JSON reads: 0 after activation.
Project-wide remaining authoritative legacy reads are listed in
`RUNTIME_JSON_DEPENDENCY_AUDIT.md`, chiefly `wanted_worker.ps1` and
`daily_cleanup.ps1`.

## Worker Legacy JSON Mirror

- read: yes, still present in the existing worker path
- write: yes, compatibility state and accepted CSV writes remain
- authoritative: SQLite is authoritative for claim/lease/CAS, but worker
  content/queue fallback reads are not yet fully SQLite-only
- recommendation-related: indirectly, through legacy canonical/wanted state

This is intentionally reported as a remaining risk, not as a write-only mirror.

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
reported imports of tracks=101, recommendations=20, history=101, events=40,
accepted=5, rejected=140, lyrics_fallback=140, wanted=2, providers=2,
display=121, explicit_likes=2, skipped=0, and conflicts=162. The existing DB
counts were canonical=81, daily=81, feedback=0, wanted=2, provider=1, and
events=1. `legacy_ignored` recorded 24 invalid lyrics rows and one legacy
`bilibili` provider. It created no backup and performed no writes.
No production DB write, runtime activation, JSON deletion, music deletion, or
Navidrome DB modification was performed.

## Bugs Found

- `CODE_BUG`: marker-only migration initially changed the existing Phase 3
  idempotency contract for a populated DB with no legacy input; the
  pre-marker/no-input compatibility path was restored and ApiTransaction is
  17/17.
- `COMPATIBILITY_BUG`: newly written PowerShell files require UTF-8 BOM for
  Windows PowerShell 5.1 to parse non-ASCII fixtures correctly; fixed in the
  Phase 4 files.
- `LEGACY_STATE_ISSUE`: worker and cleanup still have legacy JSON/CSV runtime
  reads; documented and deferred rather than silently misclassified.

## Changes Made

- Phase 4 checkpoint commit: `Integrate SQLite recommendation state` (SHA in
  final handoff)
- Changed source/test/docs files: `.github/workflows/core-tests.yml`,
  `MusicServer.Database.psm1`, `MusicServer.Migration.psm1`,
  `MusicServer.State.psm1`, `daily_recommend.ps1`,
  `tests/MusicServer.Core.Tests.ps1`,
  `tests/MusicServer.Recommendation.Tests.ps1`,
  `HARDENING_V2_REPORT.md`, `RUNTIME_JSON_DEPENDENCY_AUDIT.md`
- Untouched untracked files: `MusicServer.DesiredStateWorker.psm1`,
  `start_musicserver.ps1`, `stop_musicserver.ps1`

## Remaining Risks

- Worker JSON read retirement is still required before claiming whole-project
  SQLite-only runtime.
- `daily_cleanup.ps1` still owns operational accepted/rejected CSV workflow.
- Real successful Bilibili download E2E remains external/provider dependent and
  is outside metadata-only Phase 4.

## Final Verdict

PASS_WITH_WARNINGS — the Phase 4 recommendation generator/API migration is
complete and SQLite-authoritative, with all scoped checks green. The project
as a whole is not yet JSON-free: the existing worker and daily cleanup still
have legacy reads, as documented in the audit.
No production migration activation, legacy JSON deletion, merge, push, or PR
creation was performed.

Answers to the Phase 4 acceptance questions:

1. Phase 4: COMPLETE for the scoped recommendation/API migration; warning for
   the deferred worker/cleanup retirement.
2. Recommendation generator and API runtime: SQLite-authoritative; whole
   project: not yet.
3. Neutral recommendation history as seed: no longer used.
4. 14-day cooldown: SQLite-authoritative for the recommender.
5. accepted.csv and recommendation JSON: migration input only after activation,
   not runtime decision sources for this path.
6. Authoritative JSON/CSV reads remain in worker, cleanup, Core compatibility,
   and legacy provider-health paths.
7. Worker JSON mirror: not write-only yet; it still has legacy reads.
8. Production migration activation: ready for a separately authorized change,
   but not activated here.
9. Full v2 E2E: metadata/state/API E2E is green; successful Bilibili download
   E2E remains provider-dependent and deferred.
10. v2 PR: not created automatically; review branch remains unmerged.
