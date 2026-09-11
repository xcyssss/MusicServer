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
- `daily_recommend.ps1`
- `register_daily_recommend.ps1`
- Core/Database/Http/State/Providers/Identity/Migration modules
- `web/`
- a real `sqlite3.exe`

Do **not** package `cookies.txt`, local databases, music, logs, generated reports, yt-dlp credentials, or user-specific paths.

Installed builds default to:

```text
%LOCALAPPDATA%\com.musicserver.desktop\
```

for the writable runtime/data home. `MUSICSERVER_APP_HOME` can override it.
The music library is independently configurable. Runtime resolution order is `MUSICSERVER_MUSIC_DIR` -> SQLite `app_settings.music_library_path` -> `<APP_HOME>\Music`. All runtime entry points must use the same resolved `Config.MusicDir`, and `Config.DailyDir` must always be `<MusicDir>\DailyMix`. A missing configured custom path is an unavailable library, not a signal to fall back to or create the default library. Never move/copy/delete user music when changing this setting. Adjacent `Song.lrc` remains the lyric contract for `Song.mp3`.

An EXE launched from a source checkout must not detect that checkout and use it as persistent state. APP_HOME is resolved only from `MUSICSERVER_APP_HOME` or the platform default `%LOCALAPPDATA%\com.musicserver.desktop`; repository contents must never change that result. **Do not reintroduce `CARGO_MANIFEST_DIR` as runtime state/location.**

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
├─ register_daily_recommend.ps1   # operational setup (daily recommendation task)
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
- NetEase id discovery is a bounded fallback (one search per resolve, gated by the `netease` provider circuit, `MUSICSERVER_DISABLE_NETEASE_SEARCH=1` disables it). Never search a provider that is already blocked, and never turn `UNAVAILABLE` back into an automatic retry.
- SQLite CLI calls use batch mode, enable foreign keys before caller SQL, and separate unquoted statement terminators onto lines so `.bail on` also stops same-line scripts on SQLite 3.53.4. Preserve SQL literals/comments and complete trigger bodies; connection-local settings must be applied per invocation. Keep the existing effective synchronous default unless a separate durability change is reviewed.
- API/proxied JSON control bodies are limited to 64 KiB and a 5-second total read deadline. Empty bodies remain supported; nonempty bodies must be UTF-8 JSON objects. Reject unsupported chunked/compressed bodies before state writes or forwarding.
- Runtime logs live under `APP_HOME\logs` and every component writes through `Write-MusicServerLog` (4 MB cap, keeps `.1`/`.2`). Spawned services have discarded stdio, so `Write-Host` alone is invisible in production; keep new logging bounded and avoid per-poll noise lines.

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

## Current checkpoint — 2026-09-11

- The displayed release year is NetEase's `album.publishTime` and **never** the local file's `year` tag. For Bilibili downloads that tag holds the upload/encode year: 155 of 185 real rows cluster in 2023–2026, so trusting it would label a 1988 song as 2024. `Get-NeteasePublishYear` converts epoch ms (accepting seconds too) and returns **0 for anything implausible** rather than clamping, because a confidently wrong year is worse than none; 0 renders as nothing. It lives on `canonical_tracks.release_year` (written by `New-CanonicalTrack -ReleaseYear` / `Save-CanonicalTrackDb` / `Save-DailyRecommendationsDb`) and is cached per local file on `local_track_artists.release_year`, resolved by `Select-NeteaseArtistForTitle` (returning `publish_year`) during the launcher's artist backfill. Both overlays (`Add-ResolvedArtist`, `Get-UiLibrary`) attach `year` to **every** row at 0 by default, before the artist decision can `continue` past it, because the year belongs to the track and not to the artist decision. `Save-CanonicalTrackDb`'s UPDATE must not blank a known year: `release_year = CASE WHEN @release_year > 0 THEN @release_year ELSE release_year END`, since a re-save from a source that carries no year would otherwise erase it. A backfill pass re-queries a `netease`-sourced row whose `release_year` is still 0, so installs that predate the column fill in rather than showing no year forever. Both `release_year` columns need the explicit idempotent `PRAGMA table_info` + `ALTER TABLE` upgrade: `CREATE TABLE IF NOT EXISTS` never adds a column to an existing state DB.

- Disliking ("讨厌") is a **soft penalty, never an exclusion**, because the request was 少推荐这首歌 rather than 不要再推荐. `recommendation_feedback` gains a `DISLIKE`/`UNDISLIKE` pair `ORDER BY created_at DESC, id DESC` beside `LIKE`/`UNLIKE`, folded into one like/dislike axis by `Get-TrackPreferenceMapDb` (most recent wins) and `Get-LatestTrackPreferenceDb` (targeted, for per-track reads). Disliking writes an `UNLIKE` first and the `DISLIKE` second so the tie on a shared timestamp breaks on `id` and DISLIKE wins, which clears the heart without cancelling a download or deleting a file — `Write-TrackDislikeDb` is preference-only and never touches the wanted queue. `daily_recommend.ps1` applies `-$DislikeScorePenalty` (5, against a fresh candidate's 1–3 per seed) to online candidates and divides a disliked local pick's affinity weight by `$DislikeWeightDivisor` (4); `Get-DislikePenaltyKeys` + `Test-CandidateDisliked` match on NetEase id, canonical track id, normalized name, and normalized name+artist, so the same song is caught when it arrives from a different seed. Verified on the real library: 55 candidates → 56 (nothing removed) and the disliked tracks present at ranks 55–56 of 56, i.e. last but reachable. `$dislikedKeys` must be computed **before** the local-pick block, not next to its online use.

- `tests/MusicServer.Web.Tests.ps1` must import `MusicServer.Providers.psm1`: it dot-sources `Get-UiLibrary` out of the launcher, and that function calls `Resolve-DisplayArtist`. Without the import the test failed with "Resolve-DisplayArtist is not recognized" — a pre-existing red that only surfaced locally because the suite is run one file at a time.

- Local artists are resolved rather than read. Bilibili downloads tag the **uploader** in `media_file.artist` and sit directly in the library root, so the index value is not the singer. `local_track_artists` (`path_key` normalized absolute path → `artist`/`album`/`status`/`source`) caches one outcome per file, including `NOT_FOUND`, so a library that cannot be resolved is not re-searched every start. The launcher's single-runspace `Start-ArtistBackfill` (`MUSICSERVER_ARTIST_BACKFILL_LIMIT`, `MUSICSERVER_DISABLE_ARTIST_BACKFILL=1`) fills it, `Get-UiLibrary` and the API's `Add-ResolvedArtist` overlay it onto every library response, and the list cache is invalidated when a pass completes. The launcher calls `Initialize-LocalTrackArtistSchema` explicitly because it binds an existing DB with `Connect-MusicServerDatabase`, which by design creates nothing.

- Artist lookup precision comes from a file-name gate, not from the search ranking. `Test-FileVouchesForArtist` accepts a NetEase candidate only when the file name already contains every artist it credits: searching a song name otherwise returns a different recording (`EXO-M` for `EXO-K《mama》`, `XG` for `Hearts2Hearts《RUDE!》`). Duration is a tie-breaker only, because uploads pad or extend the song (a 1540 s single-file upload of a 279 s track is still correct). `Get-TitleSearchKeywords` tries at most three keywords (bracketed song name first, then cleaned title) and `Resolve-NeteaseTrackArtist` charges each to the `netease` circuit, stopping as soon as the circuit refuses. `Get-TitleDeclaredArtist` supplies an offline fallback for what the lookup cannot resolve: the `<artist>《<song>》` convention, plus a guarded `Song - Artist` tail that is only trusted when neither side carries brackets, series or marketing noise — guessing wrong would display a song name as an artist, which is worse than showing none.

- `Resolve-DisplayArtist` is the single display decision and both overlays (launcher `Get-UiLibrary`, API `Add-ResolvedArtist`) go through it. A cached `netease` match is final and reused; a `source = 'title'` value costs no network call and is therefore **recomputed on every read**, so improved parsing rules heal rows an older build already wrote with no migration. When the rules now refuse a title, the indexed value stays rather than being blanked. Channel branding is a prefix shared by many titles (`Get-SharedTitlePrefixes` / `Remove-SharedTitlePrefix`), so it is detected from the whole set and stripped only when it ends on a boundary character — otherwise a repeated real artist name (`许嵩《…》` four times) would be deleted as if it were branding. A declared name must also be a single credit: CJK text mixing spaces, or a long CJK run with no separator, is a comment or branding, while a Latin credit may still contain spaces (`Alan Walker&Sabrina Carpenter&Farruko`). The sentence/bracket rejection must run **before** trailing-punctuation cleanup, which would otherwise erase the `！` in `仙气空灵！` that proves the text is a comment.

- `local_track_artists.updated_at` must be produced by `Get-NowIso` before the SQL template is expanded. Templates expand parameters as literals, so passing the bare command name stores it verbatim and silently breaks the 30-day retry window.

- Hermetic runtime fixtures (`MusicServer.RuntimeFixture.ps1`, `MusicServer.UiProxyRuntime.Tests.ps1`) set `MUSICSERVER_DISABLE_ARTIST_BACKFILL=1` for the child launcher. Without it the background resolution reaches the network inside socket regressions and the suite stalls rather than failing.

- The library read path must not filter on Navidrome's `missing` column. That column is only refreshed by a Navidrome scan, and the packaged runtime never installs or runs Navidrome, so every row stays flagged `missing = 1` and `WHERE missing = 0` returns nothing. The launcher and the API now select all rows and require `[IO.File]::Exists` on the resolved path instead; `Get-LibraryFolderArtist` returns empty when a file's parent is the library root itself, so a flat library can no longer report the library name as every artist. `tests/MusicServer.ArtistResolution.Tests.ps1` covers the resolver and the gate; `tests/MusicServer.Web.Tests.ps1` pins the no-`missing`-filter and file-existence behavior. The same mistake existed a second time in `daily_recommend.ps1`'s library-seed query, so every seed silently degraded to a bare `.mp3` basename with no artist; it now reads `Get-LocalLibraryRows`, which keeps the resolved singer and the library id per row.

- Recommendations have two sources, and the split is deliberate. NetEase (`Search-Netease` + `Get-SimiSongs`) is discovery: every online candidate is a track the user does not own, and it is the only path that produces `netease` ids. The local source (`Get-LocalArtistAffinity` + `Select-LocalRecommendationTracks`, `seed_source = 'local_library'`) answers the opposite question — which owned tracks to hear again — and is **preference-led, not library-led**: a track is eligible only when the listener has already shown interest in that artist (explicit positives weight 6, play counts `min(plays, cap) * 2`), so a large untouched library cannot turn the day into a dump of its own files. A local pick must carry a library id, because playback resolves through the index and a file on disk but absent from it would be recommended as something unplayable. Picks are one-per-artist, least-recently-played first, skip anything played within 14 days, and are appended after the online picks under `-LocalCount` (default 6, 0 disables). Exclusion keys must be normalized on **both** sides: comparing a normalized lookup against raw keys silently failed for any key normalization rewrites (a library id containing a hyphen).

- `Get-SongSearchQueries` builds the NetEase query from a library track: the cleaned song name with the resolved lead artist first, then alone. Seeding with the raw uploader title wastes the lookup, and appending an artist the keyword already names (`陈奕迅 陈奕迅`, `Roselia Always recall. Roselia`) produces a string more specific than any real NetEase title, so it can never match. The search only accepts a candidate whose song name matches the query, which is a second precision gate beside `Test-FileVouchesForArtist`.

- A preview's `provider` must come from the `preview_sources` record, never be assumed: `Get-TrackPlaybackSource` reported a NetEase preview URL as `bilibili`, which misleads any caller that branches on the provider.

- Runtime logging: `Write-MusicServerLog` (bounded at 4 MB, keeps `.1`/`.2`) is the single sink under `APP_HOME\logs`. The launcher, the watchdog, the API (`musicserver-api.log`: startup, per-request line, `ERROR`, `SLOW` ≥ 3 s) and the worker (`musicserver-worker.log`: pass start, candidate choice, download/validation outcome, retry reasons) all log through it; per-poll keep-alive lines stay console-only. Previously only the launcher wrote a file, so API/worker diagnostics were silently discarded.

- Download success rate: `Test-ProviderRequestAvailable` now reports `HALF_OPEN` as available so the single allowed probe is actually claimed (`Claim-ProviderRequest` -> `Claim-HalfOpenProbeDb` keeps exclusivity); the previous `probe_pending` check deadlocked the circuit. `Search-NeteaseCandidate` adds a bounded NetEase discovery fallback for tracks without a NetEase id: at most one search per resolve, charged to the `netease` provider circuit, only when no local/direct candidate exists, disabled with `MUSICSERVER_DISABLE_NETEASE_SEARCH=1`. A discovered id is persisted through `Add-CanonicalTrackIdentifierDb`. `UNAVAILABLE` stays terminal; the 下载动态 panel renders an explicit 重试 action for `UNAVAILABLE`/`RETRY_WAIT` rows.

- The desktop runtime ships `daily_recommend.ps1`, `register_daily_recommend.ps1` and their `MusicServer.Migration.psm1` dependency. All three are staged by `scripts/prepare_tauri_runtime.ps1`, listed in the Rust runtime `REQUIRED` allowlist and included in the content build identity; `daily_recommend.ps1` takes `-AppHome` so a scheduled run is independent of environment variables. The launcher registers `MusicServer_DailyRecommend` (daily 07:00, action bound to the packaged APP_HOME) idempotently. Registration is skipped for source checkouts (`.git` present) and disabled with `MUSICSERVER_DISABLE_SCHEDULED_TASKS=1`; failures are logged and never block startup. `MusicServer_DailyCleanup` is still a legacy manual task and is not auto-registered.

- A fresh install must produce recommendations with no manual setup, which needs three things that were all previously missing. (1) `register_daily_recommend.ps1` passes `New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable` (1-hour limit, `IgnoreNew`); plain `Register-ScheduledTask` defaults refuse to start on battery and never catch up a 07:00 trigger missed while the PC was off, so laptop users silently got nothing. (2) The launcher repairs a task whose settings are stale through `Test-DailyRecommendTaskCurrent` instead of trusting the action path alone, so already-installed builds recover on the next start. (3) `Get-RecommendationSeedCandidatesDb -LibraryFallback` seeds from the local library **only when the preference pool is empty**, and `daily_recommend.ps1` reads it from a copy of the Navidrome DB (or `.mp3` basenames) — otherwise a user with no likes, stars or legacy import has zero seeds and the generator still "saves" an empty day. Backfill is keyed on `Test-DailyRecommendGeneratedToday` (any `daily_recommendations` row for today) rather than the last run time, so a run that failed mid-way is retried while a completed day is not regenerated on every APP start; a run that started within the last 15 minutes is left alone. Because the task action is pinned to `-AppHome $Root`, the health check builds its own config with `New-MusicServerConfig -Root $Root -AppHome $Root` instead of reusing the environment-resolved `$Config`, which can point at a different home. Verified end-to-end against the staged runtime in a simulated install directory: no `.git`, no `MUSICSERVER_APP_HOME`, empty day -> task registered, backfill started, packaged generator produced rows from `library_fallback`.

- `MusicServer_DailyRecommend` follows the user rather than freezing install-time state. `Get-DailyRecommendTaskPreferences` reads the trigger time and `-Count` back from the task being replaced, so a repair caused by a moved install directory, a reinstall, or stale settings written by an older build keeps the schedule the user chose instead of resetting it to 07:00 / 20. The task stores only `-AppHome`; the music library is resolved at run time by `daily_recommend.ps1` through `Apply-ConfiguredMusicDir` and `$Config.MusicDir`, so changing the library in 设置 needs no task change. A source-checkout launcher running against a packaged APP_HOME rewrites the action to that home on the next start, which is why the launcher log shows one re-registration after installing over an older build.

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
- P1-B closed: release runtime is bundled, SQLite and the UI watchdog are included, `CARGO_MANIFEST_DIR` runtime dependency is removed, installed runtime uses a writable APP home, and checkout builds no longer use repository contents as persistent state.
- Persistent paths now resolve through `MUSICSERVER_APP_HOME` (or the platform default); configurable `MusicDir` remains independent, and generated Navidrome config lives in APP_HOME. `scripts/migrate_to_app_home.ps1` is fail-closed: Navidrome must be stopped, destinations must be absent, copied files are hash-verified before legacy sources are removed, and repository `Music` is never implicitly moved.
- `desktop-build` produces an NSIS setup executable and uploads `musicserver-windows-installer`.
- CI performs an installed-app portability smoke with the checkout runtime disabled; it verifies packaged runtime staging, current UI/API markers, SQLite state creation and owned-service shutdown.
- GitHub Actions run #74 passed `state`, `api`, and `desktop-build`, including the source-independent installed-APP smoke and installer artifact upload.
- P2 closed: historical reports moved to `docs/archive/`, Chinese user guide moved to `docs/`, committed validation logs removed, personal Markdown-association scripts removed, `.editorconfig` added, and Tauri icons reduced to Windows release/source assets.
- The local main baseline includes PR #10's merge commit `a63cfef`. Subsequent optimization work uses new feature/review branches; merging any new PR still requires explicit user authorization.
- The HTTP input module is packaged with the desktop runtime and covered by real PS5.1 API/proxy socket tests in the `api` CI group.
- The Web Pester suite runs `tests/web-ui.behavior.test.cjs` with Node to cover frontend timing/state behavior. Read UTF-8 web assets explicitly in PS5.1 tests; Tauri tests compare UI/API/Rust/local-smoke/installed-CI build markers.
- `scripts/measure_musicserver_backend.ps1` measures isolated service readiness, endpoint latency and state SQLite process counts with synthetic metadata. It omits the downloader, writes only under `artifacts/`, and does not substitute for Tauri rendering/playback validation.
