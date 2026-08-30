# Runtime JSON/CSV Dependency Audit

Date: 2026-08-30
Scope: Hardening v2 Phase 4 recommendation-state migration

The important distinction in this audit is between a file that is used as a
runtime decision source and a file that is only retained as a compatibility
artifact. A migration read is allowed before the SQLite activation marker is
written. After `migration_markers.source_key = recommendation_state_v2` is
present, recommendation runtime code must not consult those legacy files.

## Recommendation runtime result

| Surface | Runtime authoritative source | Legacy JSON/CSV read after activation |
|---|---|---:|
| `daily_recommend.ps1` seed selection | SQLite feedback plus dynamic Navidrome stars | 0 |
| `daily_recommend.ps1` accepted/rejected exclusion | SQLite `ACCEPTED`/`REJECTED` feedback | 0 |
| `daily_recommend.ps1` cooldown | SQLite `daily_recommendations` | 0 |
| `music_api.ps1` recommendation list | SQLite `daily_recommendations` + canonical state | 0 |
| recommendation writes | SQLite transaction; DISPLAY feedback in SQLite | 0 |
| one-time migration | `MusicServer.Migration.psm1` JSON/CSV input | allowed before marker |

`lyrics_report.csv` is also imported as weak `LIBRARY_FALLBACK` feedback, so
the daily recommendation script no longer reads it on every run. Migration
activation is explicit: only `daily_recommend.ps1 -MigrateLegacy` invokes the
one-time importer; normal scheduled runs and `-DryRun` do not activate it.

## Inventory

### A — authoritative runtime reads remaining

These are known remaining reads and are intentionally not hidden behind the
Phase 4 recommendation claim:

| File | Read | Why it still matters | Planned disposition |
|---|---|---|---|
| `wanted_worker.ps1` | `Get-WantedTracks`, `Get-CanonicalTrack`, provider helpers through `MusicServer.Core`/`MusicServer.Providers`; startup `Import-LegacyRecommendationState` | Worker queue CAS/lease is SQLite-authoritative, but this script still uses legacy JSON snapshots for queue/content decisions and fallback guards | Phase 5 worker JSON mirror retirement |
| `daily_cleanup.ps1` | `history.csv`, `accepted.csv`, `rejected.csv` | Legacy cleanup and playlist workflow still uses CSV metadata | Migrate cleanup bookkeeping to SQLite before production activation |
| `MusicServer.Core.psm1` | `Read-StateCollection` used by legacy helper surface | Compatibility state API retained for migration/worker callers | Remove callers, then retire helper surface |
| `MusicServer.Providers.psm1` | legacy provider-health helpers read/write `providers.json` | Used by the legacy worker path | Move worker provider health reads fully to `provider_health` |

Therefore the project as a whole does still contain authoritative JSON/CSV
runtime reads. Phase 4's narrower recommendation generator and API runtime
claim is SQLite-only; this audit does not claim the worker or cleanup scripts
are already migrated.

### B — compatibility writes

| File/surface | Artifact | Role |
|---|---|---|
| `wanted_worker.ps1` and Core helpers | `tracks.json`, `wanted.json`, `recommendations.json`, `recommendation_history.json`, `events.jsonl` | Existing worker/UI compatibility mirror; not part of daily recommendation runtime |
| `wanted_worker.ps1` | `accepted.csv` | Existing cleanup/recommendation compatibility output after localization |
| `daily_cleanup.ps1` | `accepted.csv`, `rejected.csv` | Existing operational cleanup output |

The worker's current writes are compatibility writes, but its current reads are
still listed in category A above. It is not yet accurate to describe the
worker as write-only compatibility.

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
- `lyrics_report.csv`

Malformed rows are reported and skipped where possible. The imported data is
written in one SQLite transaction, and the marker is written in that same
transaction. Re-running after a committed marker returns `ALREADY_MIGRATED`
without rereading those sources.

### D — backup/export

The migration keeps a non-destructive timestamped backup of legacy source files
under `DailyMix_data/state/migration_backup_*`. The source files are never
deleted. Existing `today.csv`/JSON compatibility behavior remains available to
legacy callers until the worker and cleanup follow-up is completed.

### E — tests/artifacts

Pester fixtures, HTTP evidence, and scratch databases may use JSON/CSV for test
transport or assertions. They are not runtime state. `artifacts/` remains
git-ignored and must not be committed.

## Static checks used

- `daily_recommend.ps1` contains no `Read-StateCollection`,
  `Import-LegacyRecommendationState`, or recommendation legacy-file reads.
- `music_api.ps1` recommendation routes use `Get-TodayRecommendationsDb` and
  do not call `Read-StateCollection`.
- `wanted_worker.ps1` was deliberately not refactored in Phase 4; its remaining
  JSON reads are recorded above rather than misclassified as write-only.
