# Runtime JSON/CSV Dependency Audit

Date: 2026-08-31
Scope: Hardening v2 Phase 5 legacy runtime-read retirement and migration rehearsal

The important distinction in this audit is between a file that is used as a
runtime decision source and a file that is only retained as a compatibility
artifact. A migration read is allowed before the SQLite activation marker is
written. After `migration_markers.source_key = recommendation_state_v2` is
present, recommendation runtime code must not consult those legacy files.

## Runtime result

| Surface | Runtime authoritative source | Legacy JSON/CSV read after activation |
|---|---|---:|
| `daily_recommend.ps1` seed selection | SQLite feedback plus dynamic Navidrome stars | 0 |
| `daily_recommend.ps1` accepted/rejected exclusion | SQLite `ACCEPTED`/`REJECTED` feedback | 0 |
| `daily_recommend.ps1` cooldown | SQLite `daily_recommendations` | 0 |
| `music_api.ps1` recommendation list | SQLite `daily_recommendations` + canonical state | 0 |
| recommendation writes | SQLite transaction; DISPLAY feedback in SQLite | 0 |
| `wanted_worker.ps1` queue/claim/status/retry/cancellation | SQLite `wanted_queue` + canonical state + provider health/events | 0 |
| `daily_cleanup.ps1` decision/feedback/playlist metadata | SQLite recommendation files + feedback | 0 |
| one-time migration | `MusicServer.Migration.psm1` JSON/CSV input | allowed before marker |

`lyrics_report.csv` is also imported as weak `LIBRARY_FALLBACK` feedback, so
the daily recommendation script no longer reads it on every run. Migration
activation is explicit: only `daily_recommend.ps1 -MigrateLegacy` invokes the
one-time importer; normal scheduled runs and `-DryRun` do not activate it.
`music_api.ps1` does not import the migration module or activate migration at
startup; API restart is therefore not a legacy-state write boundary.

## Inventory

### A — remaining reader surfaces (not runtime authority)

These are remaining compatibility or migration reads, not runtime state
decisions for the migrated Worker/Cleanup paths:

| File | Read | Why it still matters | Planned disposition |
|---|---|---|---|
| `wanted_worker.ps1` | none for runtime state | Queue enumeration, claim, cancellation, retry, canonical status, provider health, and events use SQLite | Keep compatibility exports only; no legacy runtime reads |
| `daily_cleanup.ps1` | none for runtime state | Recommendation file metadata, feedback, and playlist selection use SQLite | Keep compatibility CSV exports only |
| `MusicServer.Core.psm1` | `Read-StateCollection` used by legacy helper surface | Compatibility state API retained for migration/worker callers | Remove callers, then retire helper surface |
| `MusicServer.Providers.psm1` | HTTP search response `ConvertFrom-Json` only | Provider health reads/writes use SQLite; HTTP payload parsing is not state authority | Retain HTTP response parsing |

The remaining JSON/CSV reads in the table are compatibility/migration helper
surfaces, not Worker/Cleanup runtime decisions. SQLite is the authoritative
runtime source for the migrated surfaces.

### B — compatibility writes

| File/surface | Artifact | Role |
|---|---|---|
| `wanted_worker.ps1` and Core helpers | legacy JSON/event exports where enabled | Compatibility/export artifacts; never read to decide runtime state |
| `wanted_worker.ps1` | `accepted.csv` | Compatibility output after a new SQLite ACCEPTED fact |
| `daily_cleanup.ps1` | `accepted.csv`, `rejected.csv` | Existing operational cleanup output |

These files are optional compatibility artifacts. A failed or stale export
does not change the SQLite decision that has already been committed.

### C — migration input

`MusicServer.Migration.psm1` reads the following only while the migration marker
is absent:

- `DailyMix_data/state/tracks.json`
- `DailyMix_data/state/recommendations.json`
- `DailyMix_data/state/recommendation_history.json`
- `DailyMix_data/state/events.jsonl`
- `DailyMix_data/state/wanted.json`
- `DailyMix_data/state/providers.json`
- `DailyMix_data/accepted.csv`
- `DailyMix_data/rejected.csv`
- `DailyMix_data/history.csv`
- `lyrics_report.csv`

Malformed rows are reported and skipped where possible. The imported data is
written in one SQLite transaction, and the marker is written in that same
transaction. Re-running after a committed marker returns `ALREADY_MIGRATED`
without rereading those sources.

### D — backup/export

The migration keeps a non-destructive timestamped backup of legacy source files
under `DailyMix_data/state/migration_backup_*`. The source files are never
deleted. Existing JSON/CSV compatibility behavior remains available to legacy
callers; the files are not runtime state inputs for the migrated Worker/Cleanup
paths.

### E — tests/artifacts

Pester fixtures, HTTP evidence, and scratch databases may use JSON/CSV for test
transport or assertions. They are not runtime state. `artifacts/` remains
git-ignored and must not be committed.

## Static checks used

- `daily_recommend.ps1` contains no `Read-StateCollection`,
  `Import-LegacyRecommendationState`, or recommendation legacy-file reads.
- `music_api.ps1` recommendation routes use `Get-TodayRecommendationsDb` and
  do not call `Read-StateCollection`.
- `wanted_worker.ps1` contains no legacy state-read calls and uses SQLite for
  queue, lease, cancellation, retry, canonical status, and event decisions.
- `daily_cleanup.ps1` contains no legacy CSV/JSON reads and uses SQLite for
  recommendation metadata, feedback, and playlist selection.
- `MusicServer.Providers.psm1` contains no legacy provider-health state reads;
  its remaining JSON parser handles provider HTTP responses only.
- `.github/workflows/core-tests.yml` includes `LegacyRetirement` in the state
  job so the authority checks run in CI.

## Phase 5 validation

- LegacyRetirement: 9/9 on PowerShell 7 and 9/9 on Windows PowerShell 5.1.
- PS7 state group: 113/113; PS7 API group: 22/22.
- PS5.1 state group (excluding live-runtime Web tests): 111/111; PS5.1 API
  group: 22/22.
- Authority conflict cases A-D pass: SQLite CANCEL_REQUESTED, REMOTE,
  WANTED, and UNAVAILABLE each override contradictory or missing legacy data.
- Production SQLite snapshot rehearsal: first migration `SUCCESS`, second
  migration `ALREADY_MIGRATED`, `idempotent=True`; no production files were
  modified. Conflict categories were
  `SAFE_IDEMPOTENT=162`, `EXPECTED_LEGACY_OVERLAP=20`,
  `STALE_LEGACY=4`, `IDENTITY_AMBIGUITY=0`, `SEMANTIC_CONFLICT=0`,
  `MALFORMED=0`.
- Rehearsal merge skips were `85`: `SAFE_IDEMPOTENT=81` and
  `STALE_LEGACY=4`; 24 malformed lyrics rows were separately classified as
  `MALFORMED` and reported without changing the SQLite snapshot.
