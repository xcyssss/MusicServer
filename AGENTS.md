# MusicServer - Agent Guide

MusicServer is a Windows-first local music application. The **Tauri v2 desktop APP is the product target**; `web/` is the shared WebView2 UI rendered inside that APP.

## Non-negotiable architecture rules

- **SQLite is the sole runtime source of truth.** JSON files are migration input, backup, or compatibility output only.
- **Do not build a second native Rust UI.** `web/index.html`, `web/app.js`, and `web/styles.css` are the desktop UI.
- **Keep the product all in one page.** Library and recommendations share the workspace; playback stays visible, and listening, lyrics and download details open within that page.
- **Validate user-facing UI changes in the Tauri APP**, not only in a browser.
- **Windows PowerShell 5.1 is the compatibility baseline** for formal PowerShell code and tests.
- `.ps1` / `.psm1` containing non-ASCII text must be UTF-8 BOM. `.editorconfig` enforces this.
- Never directly edit the live Navidrome DB while Navidrome is running.
- Generated runtime/build output, local music, cookies, databases, logs, and diagnostic `artifacts/` must not be committed.

## Core stack

- `MusicServer.Core.psm1` — configuration/common helpers
- `MusicServer.Database.psm1` — SQLite access
- `MusicServer.Http.psm1` — bounded UTF-8 JSON control-request reader shared by API and UI proxy
- `MusicServer.State.psm1` — canonical transactional state/schema
- `MusicServer.Providers.psm1` — local/Bilibili provider resolution and health
- `MusicServer.Migration.psm1` — explicit legacy migration only (deprecated, kept for test compatibility)
- `music_api.ps1` — JSON HTTP API, normally `127.0.0.1:8787`
- `start_musicserver_ui.ps1` — static WebView UI + `/api/*` proxy, normally `127.0.0.1:8790`
- `watchdog_ui.ps1` — external UI heartbeat watchdog/restart helper
- `wanted_worker.ps1` — asynchronous Wanted Queue downloader
- `web/` — shared desktop WebView2 UI
- `src-tauri/` — Tauri desktop shell, runtime deployment, lifecycle and packaging
- Navidrome — local music server/integration
- yt-dlp + ffmpeg/ffprobe — optional download/transcode integrations

External executable resolution should prefer environment overrides / PATH rather than new machine-specific absolute paths:

```text
MUSICSERVER_SQLITE
MUSICSERVER_YTDLP
MUSICSERVER_FFMPEG
MUSICSERVER_FFPROBE
MUSICSERVER_APP_HOME
```

## Desktop runtime and release model

A release must work independently of the source checkout.

Build flow:

```text
clean checkout
  -> scripts/prepare_tauri_runtime.ps1
  -> src-tauri/resources/runtime/ (generated)
  -> cargo/Tauri NSIS build
  -> installed APP
  -> packaged runtime copied to writable APP home
  -> PowerShell UI/API/worker/watchdog started from APP home
```

The packaged runtime contains only what the desktop APP needs to boot its own UI/API state layer:

- `start_musicserver_ui.ps1`
- `watchdog_ui.ps1`
- `music_api.ps1`
- `wanted_worker.ps1`
- Core/Database/Http/State/Providers/Identity modules
- `web/`
- a real `sqlite3.exe`

Do **not** package `cookies.txt`, local databases, music, logs, generated reports, yt-dlp credentials, or user-specific paths.

Installed builds default to:

```text
%LOCALAPPDATA%\com.musicserver.desktop\
```

for the writable runtime/data home. `MUSICSERVER_APP_HOME` can override it.
The music library is independently configurable. Runtime resolution order is `MUSICSERVER_MUSIC_DIR` -> SQLite `app_settings.music_library_path` -> `<APP_HOME>\Music`. All runtime entry points must use the same resolved `Config.MusicDir`, and `Config.DailyDir` must always be `<MusicDir>\DailyMix`. A missing configured custom path is an unavailable library, not a signal to fall back to or create the default library. Never move/copy/delete user music when changing this setting. Adjacent `Song.lrc` remains the lyric contract for `Song.mp3`.

A release EXE built and launched from inside a source checkout may detect that checkout from its own executable ancestry and continue using the existing checkout data. This runtime discovery is allowed because it embeds no compile-time absolute path. **Do not reintroduce `CARGO_MANIFEST_DIR` as runtime state/location.**

## Repository layout

```text
MusicServer/
├─ .github/workflows/             # CI
├─ docs/                          # current docs + archived historical reports
├─ scripts/
│  ├─ prepare_tauri_runtime.ps1   # build staging
│  ├─ measure_musicserver_backend.ps1
│  └─ maintenance/                # standalone maintenance utilities
│     ├─ MusicServer.Maintenance.ps1 # shared configured-library resolver
│     ├─ fetch_lyrics.ps1
│     ├─ fix_one_lyric.ps1
│     ├─ fix_tags.ps1
│     ├─ add_song.ps1
│     └─ download_bilibili_favorites.ps1
├─ src-tauri/
│  ├─ src/main.rs
│  ├─ resources/runtime/          # generated, ignored except placeholder
│  ├─ icons/                      # Windows release assets only
│  ├─ Cargo.toml / Cargo.lock
│  └─ tauri.conf.json
├─ web/
├─ tests/
├─ MusicServer.*.psm1             # core modules (do not move — $PSScriptRoot coupling)
├─ music_api.ps1                  # core runtime
├─ start_musicserver_ui.ps1       # core runtime
├─ watchdog_ui.ps1                # core runtime
├─ wanted_worker.ps1              # core runtime
├─ daily_recommend.ps1            # operational maintenance tool
├─ daily_cleanup.ps1              # operational maintenance tool
├─ lib_playlist.ps1               # shared utility (dot-sourced by daily_cleanup)
├─ register_wanted_worker.ps1     # operational setup
└─ start_musicserver_ui.bat       # convenience launcher wrapper
```

Historical architecture/hardening reports belong in `docs/archive/`, not in the repository root. Personal Windows file-association helpers do not belong in this product repository.

## Formal tests and CI

Formal suites are `tests/MusicServer.*.Tests.ps1`, Pester 3.4, PS5.1-compatible. Tests that depend on a real local library/API/lyrics report must use the `RequiresLocalRuntime` tag so CI can exclude them.

CI: `.github/workflows/core-tests.yml` on `windows-latest`.

| Job | Responsibility |
|---|---|
| `state` | Core, Database, V2, WorkerConcurrency, Recommendation, LegacyRetirement, Listening, Web, Tauri, ConfigurableLibrary, TestRunner, Identity |
| `api` | Http, UiProxyRuntime, MediaRuntime, ApiTransaction, ApiRuntime |
| `desktop-build` | real Rust/Tauri compile, NSIS installer, installed-app portability smoke, installer artifact |

The desktop gate must include at least:

```text
cargo fmt --check
cargo check --locked
Tauri NSIS build
installer exists
silent temporary install
source runtime disabled during launch
installed UI/API build markers reachable
bundled sqlite/runtime staged
APP-owned services stop after APP exits
installer artifact upload
```

Do not replace this with a static grep/Pester-only check.

## Runtime behavior rules

- Default UI/API ports: 8790 / 8787.
- Fallback pairs exist for stale/foreign listeners; do not compete with unidentified port owners.
- Tauri verifies the UI `app.js` and API `/health` build marker before reusing a service pair.
- APP shutdown must stop only the launcher/service tree that this APP owns.
- Wanted worker uses its mutex/SQLite lease logic; do not introduce duplicate workers or bypass lease ownership.
- `bilibili_direct` candidates must not trigger an unnecessary Bilibili search. Search is fallback when no usable local/direct candidate exists.
- Bilibili 412/rate-limit handling must remain bounded and health-aware; do not add unbounded retry loops.
- SQLite CLI calls use batch mode, enable foreign keys before caller SQL, and separate unquoted statement terminators onto lines so `.bail on` also stops same-line scripts on SQLite 3.53.4. Preserve SQL literals/comments and complete trigger bodies; connection-local settings must be applied per invocation. Keep the existing effective synchronous default unless a separate durability change is reviewed.
- API/proxied JSON control bodies are limited to 64 KiB and a 5-second total read deadline. Empty bodies remain supported; nonempty bodies must be UTF-8 JSON objects. Reject unsupported chunked/compressed bodies before state writes or forwarding.

## Common local operations

```powershell
# Formal examples
Import-Module Pester -RequiredVersion 3.4.0 -Force
Invoke-Pester .\tests\MusicServer.Core.Tests.ps1 -PassThru

# Desktop release
cd src-tauri
cargo fmt --check
cargo check --locked
npx --yes @tauri-apps/cli@2 build --bundles nsis
```

For live desktop smoke, use `tests/verify_tauri_desktop.ps1` and exercise the actual Tauri APP.

## Change workflow

For non-trivial work:

Batch related steps as local commits; after a meaningful stage and local validation, push the group once and verify CI. Avoid pushing each small step separately.

1. inspect current branch/files before modifying;
2. preserve unrelated local/user work;
3. make the smallest coherent change;
4. add/update regression coverage;
5. run the relevant local tests when possible;
6. push to a feature/review branch;
7. verify GitHub CI rather than assuming it is green;
8. do not merge unless the user explicitly authorizes merge.

### Checkpoint rule

After completing a meaningful task, update this `AGENTS.md` checkpoint when the task changes architecture, release behavior, test gates, or important operating rules. Keep only current durable facts; do not accumulate transient debugging notes.

## Current checkpoint — 2026-09-08

- Installed smoke restart checks the actual APP process exit and then requires all service ports closed. A nonzero taskkill tree result is diagnostic only after confirmed APP exit; it must never bypass the process/port shutdown gates. PS5.1 Tauri tests cover this distinction.

- Desktop launches PowerShell and taskkill through `background_process::command` with Windows CREATE_NO_WINDOW and disconnected standard handles. PowerShell also uses NonInteractive; do not rely on WindowStyle Hidden alone, which can briefly allocate a console. The Rust regression queries GetConsoleWindow inside a real child process. Release builds retain the Windows GUI subsystem.

- Runtime manifests use schema 2 with per-file size/SHA-256 and content build identity. Desktop validates required files, managed paths, duplicate names, hashes and reparse points before modifying APP home. Changed files are fully written and synced in APP home before individual rename replacement; this is not a whole-runtime transaction or schema rollback.
- Runtime source identity is computed by MusicServer.Identity.psm1 from sorted relative names and SHA-256 content hashes. Rust embeds the same digest at build time; UI/API cache it at process startup. Machine paths and user state are excluded. Source changes therefore cannot relabel an already running service. MUSICSERVER_DISABLE_WORKER=1 explicitly disables the downloader for isolated EXE measurements; normal startup is unchanged.

- Desktop identity probes have a 1.2-second total network deadline and a 1 MiB response cap. Only a completed HTTP 200 response with the marker in its body is accepted; declared Content-Length must match. Each launched port pair has a 30-second readiness budget including network probes and sleeps. Rust TCP regressions run in the existing desktop gate. These bounds do not cover runtime staging/process teardown or establish faster normal startup.

- `tests/run_suite.ps1` pins Pester 3.4.0, excludes RequiresLocalRuntime by default, and reports failures from TestResult (name, message and stack). Exit codes are 0/1/2 for pass/test failure/runner error; zero discovered tests is an error. The state CI group includes TestRunner subprocess regressions; the suite index is tests/README.md.

- B backend reads: recommendation assembly uses four bounded State queries (one for an empty day); health statistics use one query. Schema bootstrap groups compatible DDL while retaining the lease-column upgrade and existing durability settings.
- API Navidrome snapshots/maps live for one request only; API and UI share the stable local identity helper. UI caches serialized library responses with the existing list lifetime; explicit refresh sends `refresh=1`, and deletion invalidates the list. External downloads become visible on the existing 30-second refresh lifetime or explicit refresh.
- UI media GETs use at most four isolated runspaces, with copied file maps and explicit request contexts. Lyrics may occupy at most three slots, reserving playback capacity. Excess requests return 503/Retry-After. Lyrics have a 35-second job deadline; audio retains five-second stalled-write deadlines. Lifecycle/control handling stays on the owner loop; teardown aborts media requests and disposes the pool.
- Desktop startup probes each port pair once before identity checks and skips copying byte-identical runtime files. Same-size changes/corruption are still repaired; runtime staging behavior is covered by `cargo test --locked` in the desktop gate.
- `tests/MusicServer.MediaRuntime.Tests.ps1` covers slow lyrics/audio, bounded admission, health/heartbeat responsiveness, Range/416, disconnect recovery and explicit library-cache refresh with isolated real PS5.1 services.
- `scripts/measure_musicserver_startup.ps1` measures an actual EXE against isolated empty state and current UI/API markers, omitting the downloader. It records service readiness, not rendered UI readiness, and does not replace installed-app shutdown validation.

- Phase 1 completed and merged (PR #13): deleted `MusicServer.DesiredStateWorker.psm1` and legacy launchers.
- Phase 2 completed on `review/maintenance-layout-cleanup`: moved 5 standalone maintenance utilities (`fetch_lyrics.ps1`, `fix_one_lyric.ps1`, `fix_tags.ps1`, `add_song.ps1`, `download_bilibili_favorites.ps1`) to `scripts/maintenance/`. All use hardcoded absolute paths (no `$PSScriptRoot` coupling). All doc references updated.
- `MusicServer.Migration.psm1` is RETAINED (deprecated compatibility layer). Gated behind `daily_recommend.ps1 -MigrateLegacy` (defaults off). Imported by 4 test files (V2, Recommendation, LegacyRetirement, ApiTransaction). Runtime is completely independent. Retirement condition: all users confirmed migrated + tests refactored to direct SQLite fixtures.
- Full dependency audit at `docs/DEPENDENCY_AUDIT.md`.

- P0 closed: `music_api.ps1` is PS5.1/BOM-safe and provider direct-candidate fallback no longer leaks into unwanted Bilibili search.
- P1-A closed: CI has a real `desktop-build` gate on a clean Windows runner.
- P1-B closed: release runtime is bundled, SQLite and the UI watchdog are included, `CARGO_MANIFEST_DIR` runtime dependency is removed, installed runtime uses a writable APP home, and local checkout builds preserve existing checkout data via runtime path discovery.
- `desktop-build` produces an NSIS setup executable and uploads `musicserver-windows-installer`.
- CI performs an installed-app portability smoke with the checkout runtime disabled; it verifies packaged runtime staging, current UI/API markers, SQLite state creation and owned-service shutdown.
- GitHub Actions run #74 passed `state`, `api`, and `desktop-build`, including the source-independent installed-APP smoke and installer artifact upload.
- P2 closed: historical reports moved to `docs/archive/`, Chinese user guide moved to `docs/`, committed validation logs removed, personal Markdown-association scripts removed, `.editorconfig` added, and Tauri icons reduced to Windows release/source assets.
- The local main baseline includes PR #10's merge commit `a63cfef`. Subsequent optimization work uses new feature/review branches; merging any new PR still requires explicit user authorization.
- The HTTP input module is packaged with the desktop runtime and covered by real PS5.1 API/proxy socket tests in the `api` CI group.
- The Web Pester suite runs `tests/web-ui.behavior.test.cjs` with Node to cover frontend timing/state behavior. Read UTF-8 web assets explicitly in PS5.1 tests; Tauri tests compare UI/API/Rust/local-smoke/installed-CI build markers.
- `scripts/measure_musicserver_backend.ps1` measures isolated service readiness, endpoint latency and state SQLite process counts with synthetic metadata. It omits the downloader, writes only under `artifacts/`, and does not substitute for Tauri rendering/playback validation.
