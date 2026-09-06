# MusicServer Dependency Audit Report

> **Audit date:** 2026-09-06
> **Scope:** Full project dependency analysis, file classification, dead code detection, directory structure recommendation.
> **Method:** Static analysis of all `.ps1`, `.psm1`, `.rs`, `.toml`, `.json`, `.yml`, `.cjs` files; cross-reference of Import-Module, dot-source, function call chains, CI workflows, Tauri runtime staging, and NSIS packaging.

---

## 1. Current Architecture

```
Tauri v2 Shell (src-tauri/src/main.rs)
  │
  ├─ spawns ──→ start_musicserver_ui.ps1  (sole PS entry point)
  │                 │
  │                 ├─ starts ──→ music_api.ps1 (child process, port 8787)
  │                 │                 │
  │                 │                 ├─ Import-Module MusicServer.Core.psm1
  │                 │                 ├─ Import-Module MusicServer.Providers.psm1
  │                 │                 ├─ Import-Module MusicServer.Database.psm1
  │                 │                 ├─ Import-Module MusicServer.State.psm1
  │                 │                 └─ Import-Module MusicServer.Http.psm1
  │                 │
  │                 ├─ starts ──→ wanted_worker.ps1 (child process)
  │                 │                 ├─ Import-Module MusicServer.Core.psm1
  │                 │                 ├─ Import-Module MusicServer.State.psm1
  │                 │                 └─ Import-Module MusicServer.Providers.psm1
  │                 │
  │                 ├─ starts ──→ watchdog_ui.ps1 (background watchdog)
  │                 │
  │                 ├─ serves ──→ web/ (index.html, app.js, styles.css)
  │                 │                 └─ WebView2 in Tauri window
  │                 │
  │                 └─ proxies ──→ /api/* → music_api.ps1
  │
  └─ stages ──→ %LOCALAPPDATA%\com.musicserver.desktop\ (writable app home)

Module Dependency Graph (bottom-up):

  MusicServer.Core.psm1          [LEAF — no imports, defines Config + helpers]
  MusicServer.Database.psm1      [LEAF — no imports, SQLite CLI wrapper]
  MusicServer.Http.psm1          [LEAF — no imports, JSON request reader]
  MusicServer.State.psm1         → Core + Database
  MusicServer.Providers.psm1     → Core + State (→ Core + Database)

External Services:
  Navidrome (navidrome.db, navidrome.exe) ← read by Core, Providers
  yt-dlp + ffmpeg/ffprobe                ← used by Providers for downloads
  Netease Music API                      ← used by daily_recommend, wanted_worker

Data Directories (NOT source code):
  Music/              ← local music library (user data)
  DailyMix_data/      ← state + legacy CSV data (user/runtime data)
  Navidrome/          ← Navidrome server + its database
  logs/               ← runtime logs (generated)
  cookies.txt         ← authentication cookies (user data)
```

---

## 2. File Classification Table

### Core Runtime Files (staged into NSIS installer)

| Path | Category | Runtime | Build | Test | Called By | Calls | Recommendation |
|------|----------|---------|-------|------|-----------|-------|----------------|
| `start_musicserver_ui.ps1` | CORE_RUNTIME | YES | YES | YES (fixture) | Rust main.rs (sole PS entry) | music_api.ps1, wanted_worker.ps1, watchdog_ui.ps1, Core, Http | KEEP |
| `music_api.ps1` | CORE_RUNTIME | YES | YES | YES (fixture) | start_musicserver_ui.ps1 | Core, Providers, Database, State, Http | KEEP |
| `wanted_worker.ps1` | CORE_RUNTIME | YES | YES | YES | start_musicserver_ui.ps1 | Core, State, Providers | KEEP |
| `watchdog_ui.ps1` | CORE_RUNTIME | YES | YES | YES (fixture) | start_musicserver_ui.ps1 | (none — standalone) | KEEP |
| `MusicServer.Core.psm1` | CORE_RUNTIME | YES | YES | YES (11 tests) | music_api, wanted_worker, start_ui, daily_recommend, daily_cleanup | (none — leaf) | KEEP |
| `MusicServer.Database.psm1` | CORE_RUNTIME | YES | YES | YES (8 tests) | music_api, daily_recommend, daily_cleanup, State, Migration | (none — leaf) | KEEP |
| `MusicServer.Http.psm1` | CORE_RUNTIME | YES | YES | YES (1 test) | music_api, start_musicserver_ui | (none — leaf) | KEEP |
| `MusicServer.State.psm1` | CORE_RUNTIME | YES | YES | YES (11 tests) | music_api, wanted_worker, daily_recommend, daily_cleanup | Core, Database | KEEP |
| `MusicServer.Providers.psm1` | CORE_RUNTIME | YES | YES | YES (1 test) | music_api, wanted_worker | Core, State | KEEP |
| `web/index.html` | CORE_RUNTIME | YES | YES | YES (Web, Tauri) | Tauri WebView2 | — | KEEP |
| `web/app.js` | CORE_RUNTIME | YES | YES | YES (Web, Tauri) | Tauri WebView2 | — | KEEP |
| `web/styles.css` | CORE_RUNTIME | YES | YES | NO | Tauri WebView2 | — | KEEP |

### Build & CI Infrastructure

| Path | Category | Runtime | Build | Test | Called By | Recommendation |
|------|----------|---------|-------|------|-----------|----------------|
| `src-tauri/` | CORE_BUILD | — | YES | YES | Cargo, Tauri CLI | KEEP |
| `scripts/prepare_tauri_runtime.ps1` | CORE_BUILD | — | YES | YES (Tauri.Tests) | tauri.conf.json beforeBuildCommand | KEEP |
| `scripts/measure_musicserver_backend.ps1` | DEV_INFRA | — | — | — | manual only | KEEP |
| `.github/workflows/core-tests.yml` | DEV_INFRA | — | YES | YES | GitHub Actions | KEEP |

### Test Infrastructure

| Path | Category | Runtime | Build | Test | Imports | Recommendation |
|------|----------|---------|-------|------|---------|----------------|
| `tests/MusicServer.Core.Tests.ps1` | DEV_INFRA | — | — | YES | Core, Providers | KEEP |
| `tests/MusicServer.Database.Tests.ps1` | DEV_INFRA | — | — | YES | Database | KEEP |
| `tests/MusicServer.State.Tests.ps1` (V2) | DEV_INFRA | — | — | YES | Core, Database, State, **Migration** | KEEP |
| `tests/MusicServer.WorkerConcurrency.Tests.ps1` | DEV_INFRA | — | — | YES | Core, Database, State | KEEP |
| `tests/MusicServer.Recommendation.Tests.ps1` | DEV_INFRA | — | — | YES | Core, Database, State, **Migration** | KEEP |
| `tests/MusicServer.LegacyRetirement.Tests.ps1` | DEV_INFRA | — | — | YES | Core, Database, State, **Migration** | KEEP |
| `tests/MusicServer.Listening.Tests.ps1` | DEV_INFRA | — | — | YES | Core, Database, State | KEEP |
| `tests/MusicServer.Web.Tests.ps1` | DEV_INFRA | — | — | YES | node:test, web/ | KEEP |
| `tests/MusicServer.Tauri.Tests.ps1` | DEV_INFRA | — | — | YES | config files, Http | KEEP |
| `tests/MusicServer.Http.Tests.ps1` | DEV_INFRA | — | — | YES | Http, RuntimeFixture | KEEP |
| `tests/MusicServer.UiProxyRuntime.Tests.ps1` | DEV_INFRA | — | — | YES | Core, Database, State | KEEP |
| `tests/MusicServer.ApiTransaction.Tests.ps1` | DEV_INFRA | — | — | YES | Core, Database, State, **Migration** | KEEP |
| `tests/MusicServer.ApiRuntime.Tests.ps1` | DEV_INFRA | — | — | YES | Core, Database, State | KEEP |
| `tests/MusicServer.RuntimeFixture.ps1` | DEV_INFRA | — | — | YES | Core, Database, State | KEEP |
| `tests/MusicServer.WorkerChild.ps1` | DEV_INFRA | — | — | YES | Core, Database, State | KEEP |
| `tests/MusicServer.HttpRacer.ps1` | DEV_INFRA | — | — | YES | (none) | KEEP |
| `tests/web-ui.behavior.test.cjs` | DEV_INFRA | — | — | YES | node:test | KEEP |
| `tests/run_suite.ps1` | DEV_INFRA | — | — | — | Pester | KEEP |
| `tests/verify_tauri_desktop.ps1` | DEV_INFRA | — | — | — | manual | KEEP |
| `tests/worker_smoke.ps1` | DEV_INFRA | — | — | — | manual (hardcoded paths) | KEEP |

### Maintenance Scripts

| Path | Category | Runtime | Build | Test | Imports | Recommendation |
|------|----------|---------|-------|------|---------|----------------|
| `daily_recommend.ps1` | MAINTENANCE_TOOL | — | — | YES (static analysis) | Core, Database, State, Migration | KEEP_IN_ROOT |
| `daily_cleanup.ps1` | MAINTENANCE_TOOL | — | — | YES (static analysis) | Core, Database, State, lib_playlist | KEEP_IN_ROOT |
| `lib_playlist.ps1` | MAINTENANCE_TOOL | — | — | — | (none — IS a library) | KEEP_IN_ROOT |
| `register_wanted_worker.ps1` | MAINTENANCE_TOOL | — | — | — | (none) | KEEP_IN_ROOT |
| `fetch_lyrics.ps1` | MAINTENANCE_TOOL | — | — | — | (none) | MOVE_TO_SCRIPTS |
| `fix_one_lyric.ps1` | MAINTENANCE_TOOL | — | — | — | (none) | MOVE_TO_SCRIPTS |
| `fix_tags.ps1` | MAINTENANCE_TOOL | — | — | — | (none) | MOVE_TO_SCRIPTS |
| `add_song.ps1` | MAINTENANCE_TOOL | — | — | — | (none) | MOVE_TO_SCRIPTS |
| `download_bilibili_favorites.ps1` | MAINTENANCE_TOOL | — | — | — | (none) | MOVE_TO_SCRIPTS |

### Legacy Launchers (superseded by Tauri APP)

| Path | Category | Runtime | Build | Test | Called By | Recommendation |
|------|----------|---------|-------|------|-----------|----------------|
| `start_musicserver.ps1` | HISTORICAL | — | — | — | stop_musicserver.ps1 (gitignored) | DEPRECATE |
| `start_musicserver.cmd` | HISTORICAL | — | — | — | (none — gitignored) | DEPRECATE |
| `start_musicserver.vbs` | HISTORICAL | — | — | — | .lnk shortcut (gitignored) | DEPRECATE |
| `start_navidrome.ps1` | HISTORICAL | — | — | — | 3 legacy launchers | DEPRECATE |
| `stop_musicserver.ps1` | HISTORICAL | — | — | — | start_musicserver.ps1 (gitignored) | DEPRECATE |
| `start_musicserver_ui.bat` | CORE_RUNTIME | — | — | YES (Web.Tests) | manual convenience wrapper | KEEP |

### Legacy/Orphaned Modules

| Path | Category | Runtime | Build | Test | Importers | Recommendation |
|------|----------|---------|-------|------|-----------|----------------|
| `MusicServer.DesiredStateWorker.psm1` | SUSPECTED_DEAD | — | — | — | **NONE** | **DELETE** |
| `MusicServer.Migration.psm1` | MIGRATION_ONLY | — | — | YES (4 tests) | daily_recommend (gated), 4 test files | DEPRECATE |

### Root-level Misc Files

| Path | Category | Recommendation |
|------|----------|----------------|
| `AGENTS.md` | DEV_INFRA | KEEP |
| `README.md` | DEV_INFRA | KEEP |
| `.editorconfig` | DEV_INFRA | KEEP |
| `.gitignore` | DEV_INFRA | KEEP |
| `cookies.txt` | USER_DATA | DO_NOT_TOUCH (gitignored) |
| `lyrics_report.csv` | GENERATED | DO_NOT_TOUCH (gitignored) |
| `*.lnk.before-*` | HISTORICAL | DELETE_AFTER_VERIFICATION |

### Data/Generated Directories

| Path | Category | Recommendation |
|------|----------|----------------|
| `Music/` | USER_DATA | DO_NOT_TOUCH (gitignored) |
| `DailyMix_data/` | USER_DATA | DO_NOT_TOUCH (gitignored) |
| `Navidrome/` | USER_DATA | DO_NOT_TOUCH (gitignored) |
| `logs/` | GENERATED | DO_NOT_TOUCH (gitignored) |
| `artifacts/` | GENERATED | DO_NOT_TOUCH (gitignored) |
| `backups/` | GENERATED | DO_NOT_TOUCH (gitignored) |
| `output/` | GENERATED | DO_NOT_TOUCH (gitignored) |
| `docs/` | DEV_INFRA | KEEP |
| `docs/archive/` | HISTORICAL | KEEP |

---

## 3. Core Runtime Minimum Set

> "If only keeping the files needed for an installed MusicServer APP to start and run:"

```
src-tauri/                          (Tauri shell + NSIS packaging)
  src/main.rs
  Cargo.toml / Cargo.lock
  tauri.conf.json
  build.rs
  capabilities/default.json
  icons/icon.ico
  resources/runtime/                (generated by prepare_tauri_runtime.ps1)
    start_musicserver_ui.ps1        ← Rust sole entry point
    watchdog_ui.ps1                 ← external heartbeat watchdog
    music_api.ps1                   ← HTTP API server
    wanted_worker.ps1               ← background downloader
    MusicServer.Core.psm1           ← config + helpers
    MusicServer.Database.psm1       ← SQLite access
    MusicServer.Http.psm1           ← JSON request reader
    MusicServer.State.psm1          ← transactional state
    MusicServer.Providers.psm1      ← download providers
    runtime-manifest.json           ← build-time record
    tools/sqlite3.exe               ← bundled SQLite
    web/
      index.html
      app.js
      styles.css
```

**Total: 9 scripts/modules + 3 web files + 1 SQLite binary + 1 manifest + Tauri Rust source.**

That is the **entire** runtime surface. Everything else is development, testing, maintenance, or user data.

---

## 4. Development Minimum Set

> "If continuing development, running tests, and building installers:"

```
(All of the above, PLUS:)

scripts/
  prepare_tauri_runtime.ps1         ← build staging
  measure_musicserver_backend.ps1   ← perf benchmarking

MusicServer.DesiredStateWorker.psm1 ← (will be deleted, see §5)
MusicServer.Migration.psm1         ← (deprecated, still needed by 4 test files)

daily_recommend.ps1                 ← tested by Core.Tests, Recommendation.Tests
daily_cleanup.ps1                   ← tested by LegacyRetirement.Tests
lib_playlist.ps1                    ← dot-sourced by daily_cleanup.ps1

web/
  (same 3 files — source and runtime are identical)

tests/
  (all 17 test files + helpers)

.github/workflows/
  core-tests.yml

docs/
  (current docs + archive)

.editorconfig
.gitignore
AGENTS.md
README.md
```

---

## 5. Suspected Redundancy / Dead Code

### High Confidence Dead / Redundant

#### `MusicServer.DesiredStateWorker.psm1` — DEAD CODE

| Evidence | Detail |
|----------|--------|
| Importers | **ZERO** — no `.ps1` or `.psm1` file imports it |
| Callers | **ZERO** — no exported function is called anywhere |
| Tests | **ZERO** — no test file exercises it |
| Tauri bundle | **NOT staged** — excluded from `prepare_tauri_runtime.ps1` |
| CI | **NOT referenced** in any workflow step |
| Superseded by | `wanted_worker.ps1` (richer provider support, crash recovery, lyrics, NetEase, multi-check cancellation) |

- **Risk if deleted:** ZERO. Pure dead code.
- **Verification:** `rg "DesiredStateWorker" E:\Project\MusicServer` — only matches in `AGENTS.md` and `docs/archive/`.
- **Recommendation: DELETE**

#### Legacy Launchers — DEPRECATED

| File | Evidence | Risk | Verification |
|------|----------|------|-------------|
| `start_musicserver.ps1` | Already gitignored (line 62). Superseded by `start_musicserver_ui.ps1`. | None — gitignored | Verify no `.lnk` points to it |
| `start_musicserver.cmd` | Comment in `start_musicserver_ui.ps1:132` calls it "old launcher generation" | None | Verify no shortcut references it |
| `start_musicserver.vbs` | Only caller is gitignored `.lnk` shortcut | None | Verify shortcut removed |
| `start_navidrome.ps1` | All 3 callers are legacy launchers above | None | Check no scheduled task references it |
| `stop_musicserver.ps1` | Already gitignored (line 63). Depends on PID file from legacy launcher | None | Check no scheduled task references it |

- **Risk if deleted:** LOW. Already gitignored. No runtime or test dependency.
- **Verification:** Check Windows Task Scheduler for any remaining scheduled tasks referencing these scripts.
- **Recommendation: DELETE_AFTER_VERIFICATION**

#### `*.lnk.before-*` files — HISTORICAL

| File | Evidence |
|------|----------|
| `Navidrome 音乐服务器.lnk.before-musicserver` | Backup of old shortcut, not functional |
| `Navidrome 音乐服务器.lnk.before-vbs` | Backup of old shortcut, not functional |

- **Risk if deleted:** ZERO.
- **Recommendation: DELETE**

### Medium Confidence

#### `MusicServer.Migration.psm1` — DEPRECATED, KEEP TEMPORARILY

| Evidence | Detail |
|----------|--------|
| Importers | 1 production (`daily_recommend.ps1:39`, gated behind `-MigrateLegacy`) + 4 test files |
| Runtime | NOT in Tauri bundle, NOT in normal daily flow |
| Purpose | One-time legacy JSON/CSV → SQLite migration |
| Idempotent | YES — `migration_markers` table prevents re-execution |
| Test impact | 4 test files import it: V2, Recommendation, LegacyRetirement, ApiTransaction |

- **Risk if deleted now:** LOW-MODERATE — 4 test files would break, users with unmigrated legacy data lose recovery path.
- **Verification:** Query `SELECT * FROM migration_markers WHERE source_key = 'recommendation_state_v2'` in production DB. If marker exists, migration is complete.
- **Recommendation: DEPRECATE** — add `# DEPRECATED` header, keep until next release cycle, then retire along with its 4 test imports.

#### `scan_library_mismatch.ps1` — ALREADY GITIGNORED

| Evidence | Detail |
|----------|--------|
| .gitignore | Line 61: `/scan_library_mismatch.ps1` |
| References | Only in .gitignore itself |
| Purpose | One-time diagnostic comparing filenames vs ID3 metadata |

- **Risk if deleted:** ZERO — already gitignored, one-time tool.
- **Recommendation: DELETE_AFTER_VERIFICATION**

### Low Confidence

#### `register_wanted_worker.ps1` — OPERATIONAL UTILITY

| Evidence | Detail |
|----------|--------|
| Purpose | Register/remove Windows Scheduled Task for wanted_worker.ps1 |
| References | Only in `IMPLEMENTATION_REPORT.md` |
| Runtime | Not in Tauri bundle (Tauri app manages worker lifecycle internally) |
| Still needed? | Possibly — if user still uses Windows Scheduled Task as fallback |

- **Risk if deleted:** LOW — only affects users who registered the worker via this script.
- **Verification:** `Get-ScheduledTask -TaskName 'MusicServer_WantedWorker'` on user machine.
- **Recommendation: KEEP_IN_ROOT** until confirmed no longer needed.

---

## 6. Recommended Target Directory Structure

```
MusicServer/
├── src-tauri/                          # Tauri desktop shell (DO NOT MOVE)
│   ├── src/main.rs
│   ├── Cargo.toml / Cargo.lock
│   ├── tauri.conf.json
│   ├── build.rs
│   ├── capabilities/
│   ├── icons/
│   └── resources/runtime/             # GENERATED by prepare_tauri_runtime.ps1
│
├── web/                                # Desktop WebView2 UI (DO NOT MOVE)
│   ├── index.html
│   ├── app.js
│   └── styles.css
│
├── MusicServer.Core.psm1              # Core modules (DO NOT MOVE — $PSScriptRoot coupling)
├── MusicServer.Database.psm1
├── MusicServer.Http.psm1
├── MusicServer.State.psm1
├── MusicServer.Providers.psm1
├── MusicServer.Migration.psm1         # DEPRECATED — keep for test compatibility
│
├── music_api.ps1                      # Core runtime scripts (DO NOT MOVE)
├── start_musicserver_ui.ps1
├── watchdog_ui.ps1
├── wanted_worker.ps1
├── start_musicserver_ui.bat           # Convenience launcher wrapper
│
├── daily_recommend.ps1                # Active maintenance tools (KEEP IN ROOT)
├── daily_cleanup.ps1
├── lib_playlist.ps1
├── register_wanted_worker.ps1
│
├── scripts/
│   ├── prepare_tauri_runtime.ps1      # Build tooling
│   ├── measure_musicserver_backend.ps1 # Performance tooling
│   └── maintenance/                   # MOVE here: standalone utilities
│       ├── fetch_lyrics.ps1
│       ├── fix_one_lyric.ps1
│       ├── fix_tags.ps1
│       ├── add_song.ps1
│       └── download_bilibili_favorites.ps1
│
├── tests/                             # All test infrastructure
│   ├── MusicServer.*.Tests.ps1
│   ├── MusicServer.*.ps1 (helpers)
│   ├── web-ui.behavior.test.cjs
│   ├── run_suite.ps1
│   └── verify_tauri_desktop.ps1
│
├── docs/                              # Documentation
│   ├── DEPENDENCY_AUDIT.md
│   ├── USER_GUIDE.zh-CN.md
│   ├── README.md
│   └── archive/
│
├── .github/workflows/
│   └── core-tests.yml
│
├── AGENTS.md
├── README.md
├── .editorconfig
├── .gitignore
└── cookies.txt                        # (gitignored, user data)
```

**Why NOT move core modules to `src/powershell/`:**
- All 4 inter-module imports use `Import-Module (Join-Path $PSScriptRoot ...)` — moving breaks every one.
- `MusicServer.Core.psm1` defaults `$Root = $PSScriptRoot` for path resolution — moving silently corrupts all data directory paths.
- 20+ consumer scripts (5 production + 12 tests + 4 modules) hard-code project-root-relative import paths.
- `src-tauri/resources/runtime/` has parallel copies that must stay in sync.
- Risk/benefit ratio does not justify the move.

---

## 7. Phased Refactoring Plan

### Phase 0 — Audit Only (THIS REPORT)
- **Scope:** No code changes. Dependency analysis and classification only.
- **Risk:** None.
- **Rollback:** N/A.
- **Must pass:** N/A.

### Phase 1 — Safe Cleanup

**Scope:**
1. Delete `MusicServer.DesiredStateWorker.psm1` (zero importers, zero callers, zero tests)
2. Delete `*.lnk.before-*` files (historical backup shortcuts)
3. Delete legacy launcher scripts **after verifying** no scheduled task or shortcut references them:
   - `start_musicserver.ps1` (already gitignored)
   - `start_musicserver.cmd`
   - `start_musicserver.vbs`
   - `start_navidrome.ps1`
   - `stop_musicserver.ps1` (already gitignored)

**Files modified:** 0 (deletions only)
**Risk:** LOW — all deleted files have zero runtime/test/CI dependencies.
**Rollback:** `git checkout -- <file>` for each deleted file.
**Must pass:**
- `state` CI green
- `api` CI green
- `desktop-build` CI green

### Phase 2 — Maintenance Scripts Reorganization

**Scope:**
1. Move 5 standalone utilities to `scripts/maintenance/`:
   - `fetch_lyrics.ps1`
   - `fix_one_lyric.ps1`
   - `fix_tags.ps1`
   - `add_song.ps1`
   - `download_bilibili_favorites.ps1`
2. Update `docs/USER_GUIDE.zh-CN.md` if it references old paths.
3. Update `AGENTS.md` repository layout section.
4. Update `.gitignore` if any moved scripts were explicitly listed.

**Files modified:** ~5 moved, ~3 docs updated.
**Risk:** LOW — none of the 5 scripts have automated callers, test imports, or CI references. They are all standalone manual tools.
**Rollback:** Move files back to root, revert doc changes.
**Must pass:**
- `state` CI green
- `api` CI green
- `desktop-build` CI green
- Manual: `.\scripts\maintenance\fetch_lyrics.ps1` still works (relative paths)

### Phase 3 — Legacy Retirement

**Scope:**
1. Add `# DEPRECATED` header to `MusicServer.Migration.psm1`.
2. In `daily_recommend.ps1`, add deprecation warning when `-MigrateLegacy` is used.
3. (Future release) Remove `MusicServer.Migration.psm1` and update 4 test files that import it.

**Files modified:** 2 (headers/comments only in Phase 3a).
**Risk:** LOW — no functional change. Deprecation headers are documentation-only.
**Rollback:** Revert header comments.
**Must pass:**
- `state` CI green
- `api` CI green
- `desktop-build` CI green

### Phase 4 — Optional Core Layout Refactor (NOT RECOMMENDED)

**Scope:** Move `MusicServer.*.psm1` to `src/powershell/` with a `$ProjectRoot` resolution pattern.

**Why NOT recommended:**
- 10 inter-module import lines break
- `New-MusicServerConfig` default `$Root = $PSScriptRoot` silently corrupts paths
- 20+ consumer scripts need import path updates
- Tauri runtime copies need build process changes
- `worker_smoke.ps1` has hardcoded absolute paths

**Risk:** HIGH — silent path corruption if any reference is missed.
**Only do this if:** The root directory clutter is causing actual developer friction that outweighs the migration risk.

---

## 8. Acceptance Criteria

Any actual cleanup PR must satisfy ALL of:

```
[ ] state CI green
[ ] api CI green
[ ] desktop-build CI green
[ ] cargo fmt --check
[ ] cargo check --locked
[ ] NSIS build success
[ ] installed APP without source runtime smoke success
[ ] Tauri APP UI can start
[ ] API reachable (/health → ok)
[ ] SQLite state initializes
[ ] APP shutdown cleans owned services
[ ] local music/user data untouched (Music/, DailyMix_data/, Navidrome/, cookies.txt, *.db)
```

---

## 9. Summary Conclusions

### A. True Project Core
The **9 PowerShell scripts/modules** staged by `prepare_tauri_runtime.ps1` (4 scripts + 5 modules) plus `web/` (3 files), `tools/sqlite3.exe`, and `runtime-manifest.json` constitute the complete Tauri runtime bundle (14 files total, or 11 logical items counting `web/` as one directory). The `src-tauri/` Rust shell wraps these into the desktop APP. Everything else is development infrastructure, maintenance tooling, or user data.

### B. Development Infrastructure
13 test files, `scripts/`, `.github/`, `docs/`, `AGENTS.md`, `README.md`, `.editorconfig`, `.gitignore` — all essential for continued development and CI.

### C. Auxiliary Scripts
`daily_recommend.ps1`, `daily_cleanup.ps1`, `lib_playlist.ps1`, `register_wanted_worker.ps1` — actively used scheduled/interactive maintenance tools that should stay in root for now. Five standalone utilities (`fetch_lyrics.ps1`, `fix_one_lyric.ps1`, `fix_tags.ps1`, `add_song.ps1`, `download_bilibili_favorites.ps1`) can safely move to `scripts/maintenance/`.

### D. Redundant (Phase 1 — DELETED)
- `MusicServer.DesiredStateWorker.psm1` — **confirmed dead code**. Zero importers, zero callers, zero tests. Deleted in Phase 1.
- `start_musicserver.cmd` — legacy launcher, superseded by Tauri APP. Zero scheduled tasks. Deleted in Phase 1.
- `start_musicserver.vbs` — legacy launcher, superseded by Tauri APP. Zero desktop shortcuts. Deleted in Phase 1.
- `start_navidrome.ps1` — legacy Navidrome launcher, only callers were the two launchers above. Deleted in Phase 1.
- `*.lnk.before-*` — historical shortcut backups, not git-tracked (local-only cleanup).
- `start_musicserver.ps1` / `stop_musicserver.ps1` — already gitignored, not git-tracked (local-only cleanup).

### E. Can Clean Now (Phase 1) — Verification Complete

> Phase 1 executed on `review/phase1-safe-cleanup` branch. All verifications passed.

1. **Delete `MusicServer.DesiredStateWorker.psm1`** — VERIFIED: zero importers, zero callers, zero tests, zero CI refs. DONE.
2. **Delete `*.lnk.before-*`** — NOT git-tracked (gitignored), local-only cleanup.
3. **Delete legacy launcher scripts:**
   - `start_musicserver.cmd` — VERIFIED: zero code deps, zero scheduled tasks, zero desktop shortcuts. DONE.
   - `start_musicserver.vbs` — VERIFIED: zero code deps, zero scheduled tasks, zero desktop shortcuts. DONE.
   - `start_navidrome.ps1` — VERIFIED: only callers are the two launchers above. DONE.
   - `start_musicserver.ps1` — NOT git-tracked (gitignored), local-only cleanup.
   - `stop_musicserver.ps1` — NOT git-tracked (gitignored), local-only cleanup.

### F. Do Not Touch
- All 5 core `.psm1` modules (moving breaks `$PSScriptRoot` coupling across 20+ files)
- All 4 core runtime `.ps1` scripts (`music_api`, `start_musicserver_ui`, `watchdog_ui`, `wanted_worker`)
- `web/` directory
- `src-tauri/` directory structure
- `MusicServer.Migration.psm1` (deprecated but still needed by 4 test files)
- Any `Music/`, `DailyMix_data/`, `Navidrome/`, `cookies.txt`, `*.db`, `logs/` content
