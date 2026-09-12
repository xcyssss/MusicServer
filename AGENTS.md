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

An EXE launched from a source checkout must not detect that checkout and use it as persistent state. APP_HOME resolves from `MUSICSERVER_APP_HOME`, else the machine pin `HKCU\Software\MusicServerRuntime\AppHome`, else the platform default `%LOCALAPPDATA%\com.musicserver.desktop`; repository contents must never change that result. **Do not reintroduce `CARGO_MANIFEST_DIR` as runtime state/location.**

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

### Local test strategy — targeted by default, never a serial full run

These are hard constraints, not preferences. The failure mode they exist to prevent is a "thunder test": a local verification run that takes tens of minutes to over an hour and still produces no verdict, because one suite deadlocked and nothing had a bound.

```text
Default to targeted tests.
Never run the entire local regression suite during ordinary development.
Never synchronously wait for GitHub CI with `gh pr checks --watch`.
Investigate any targeted local test exceeding 5 minutes.
Full validation is reserved for explicit final/release verification.
```

**1. Targeted by default.** After an ordinary change, run only the suites that the change can actually break. The full regression is reserved for an explicit request — 全量验证 / release / final verification — and never run "just to be safe". The goal is to catch what this change broke, quickly; it is not release-level validation every time.

**2. Never serialize every suite.** CI already splits the work into the `state` and `api` groups and runs them **in parallel**. Do not rebuild that as a local `foreach` loop over all suites: the api suites really start `powershell.exe`, `music_api.ps1`, `start_musicserver_ui.ps1`, HTTP listeners, SQLite fixtures and TCP sockets, each with a 40-second startup allowance, 15-second socket timeouts and deliberate `Start-Sleep` slow-I/O fixtures, so a serial pass is an hour-class job. When a change genuinely spans both groups, run them once, side by side:

```powershell
# Both groups in parallel, CI's own suite lists
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\run_groups.ps1

# A targeted subset instead of a whole group
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\run_groups.ps1 -StateSuites Database,Recommendation -ApiSuites Http
```

Inside a group the suites stay sequential on purpose: the api suites bind real ports, so starting them concurrently would make the run flaky rather than fast.

**3. Never block a shell on CI.** GitHub Actions runs remotely. Check it once and report the status:

```powershell
gh pr checks <PR号>
```

`gh pr checks --watch` and any other long-lived poll are forbidden: they park a shell for tens of minutes and hide nothing useful. If a check is still `pending`, say so and move on.

**4. Hard wall-clock bounds.** `tests/run_suite.ps1` bounds each suite (`-TimeoutSeconds`, default **300**) and reports `TIMEOUT: <suite>` with exit code 3 instead of waiting forever; `run_groups.ps1` bounds each group (`-GroupTimeoutSeconds`, default **900**). Budgets:

| Scope | Budget |
|---|---|
| one targeted suite | ≤ 5 minutes |
| one local group | 10–15 minutes |
| any background test or CI watcher | ≤ 15 minutes, then stop and report |

A suite past its budget is a finding, not an inconvenience: stop it and investigate **which** test, child process, port, HTTP request or timeout is stuck. Do not "give it a bit longer", and do not re-run the same thing serially to make it look green. A group that completes fewer suites than it was given is a runner error, never a pass — "0 suites ran" must not read as green.

**5. One coherent fix per failure.** Do not loop through failure → tweak an assertion → re-run → tweak again → re-run. Read the failure, find the root cause, make one coherent fix, then re-run only the smallest affected suite. Reach for a bounded child process to isolate *where* something hangs rather than guessing from a stall.

**6. Keep progress visible.** Never pipe a long run through `Select-Object -Last N`: it cannot emit until the pipeline ends, so the run looks identical whether it is progressing or wedged. Use `Tee-Object` to a log file, or write the log and poll it.

**7. Clean up what you start.** Any test that starts a real child process, HTTP service, Tauri app, PowerShell child or temporary port must clean it up on failure and timeout as well as success. The runner kills the whole tree (`taskkill /T`) when a suite overruns, because a leaked listener or worker makes the next suite wait tens of seconds and manufactures a slowdown that looks like a product bug.

**8. What to run for what.** Ordinary business-logic changes must not default to an NSIS build, a full Tauri smoke, or every Pester suite.

| Change | Run |
|---|---|
| `web/`, `tests/web-ui.behavior.test.cjs` | `node --test tests/web-ui.behavior.test.cjs`, then `MusicServer.Web.Tests.ps1` |
| one module (`MusicServer.*.psm1`) | the suites that import it plus their direct neighbours |
| `music_api.ps1` / HTTP surface | `MusicServer.Http.Tests.ps1`, `MusicServer.ApiRuntime.Tests.ps1` |
| database / state logic | `MusicServer.Database.Tests.ps1`, `MusicServer.V2.Tests.ps1`, the owning business suite |
| recommendation scoring | `MusicServer.Recommendation.Tests.ps1` and its direct dependencies |
| `start_musicserver_ui.ps1` / media | `MusicServer.UiProxyRuntime.Tests.ps1`, `MusicServer.MediaRuntime.Tests.ps1` |
| `src-tauri/`, runtime staging, installer, startup/lifecycle | the full `desktop-build` gate |

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
5. run the **targeted** local tests for this change (see *Local test strategy* — not the whole suite);
6. push to a feature/review branch;
7. check GitHub CI **once** with `gh pr checks <PR号>`; report the status rather than watching it;
8. do not merge unless the user explicitly authorizes merge.

### Checkpoint rule

After completing a meaningful task, update this `AGENTS.md` checkpoint when the task changes architecture, release behavior, test gates, or important operating rules. Keep only current durable facts; do not accumulate transient debugging notes.

## Current checkpoint — 2026-09-12

- Local verification is **targeted by default**, and the "thunder test" is a named failure mode: a serial pass over every suite is an hour-class job that produces no verdict. The rules live in *Local test strategy* above; the operational summary is: run only the suites the change can break; never serialize every suite locally; check CI with a single `gh pr checks <PR号>` instead of `--watch`; treat a targeted suite past 5 minutes, a group past 15, and any background watcher past 15 minutes as a finding to investigate and stop. Full regression is reserved for an explicit 全量验证 / release / final-verification request. `tests/run_suite.ps1` bounds each suite (`-TimeoutSeconds`, default 300, exit 3 on timeout) and `tests/run_groups.ps1` runs CI's `state` and `api` groups in parallel with a per-group bound (default 900).

- The bounded runner executes the suite in a **child process**, and two PowerShell traps there are load-bearing. (1) `Start-Process -PassThru` without `-Wait` does not keep a process handle, so `.ExitCode` reads as `$null` — and `exit $null` is exit code **0**, which reported a crashed suite as a pass. The runner uses `System.Diagnostics.Process` directly and still treats a `$null` exit code as a runner error rather than a pass. (2) A child started with `CreateNoWindow` has no console, so `[Console]::OutputEncoding` falls back to the ANSI code page and any sqlite `-json` output containing CJK comes back mangled; the worker sets UTF-8 explicitly before running Pester. Killing an overrunning suite uses `taskkill /T` so the tree the suite started (API servers, fixtures, workers) dies with it — a leaked listener makes the next suite wait and manufactures a slowdown that looks like a product bug. A group that completes fewer suites than it was given is a runner error, never a pass: "0 suites ran" must not read as green.

- The displayed release year is NetEase's `album.publishTime` and **never** the local file's `year` tag. For Bilibili downloads that tag holds the upload/encode year: 155 of 185 real rows cluster in 2023–2026, so trusting it would label a 1988 song as 2024. `Get-NeteasePublishYear` converts epoch ms (accepting seconds too) and returns **0 for anything implausible** rather than clamping, because a confidently wrong year is worse than none; 0 renders as nothing. It lives on `canonical_tracks.release_year` (written by `New-CanonicalTrack -ReleaseYear` / `Save-CanonicalTrackDb` / `Save-DailyRecommendationsDb`) and is cached per local file on `local_track_artists.release_year`, resolved by `Select-NeteaseArtistForTitle` (returning `publish_year`) during the launcher's artist backfill. Both overlays (`Add-ResolvedArtist`, `Get-UiLibrary`) attach `year` to **every** row at 0 by default, before the artist decision can `continue` past it, because the year belongs to the track and not to the artist decision. `Save-CanonicalTrackDb`'s UPDATE must not blank a known year: `release_year = CASE WHEN @release_year > 0 THEN @release_year ELSE release_year END`, since a re-save from a source that carries no year would otherwise erase it. A backfill pass re-queries a `netease`-sourced row whose `release_year` is still 0, so installs that predate the column fill in rather than showing no year forever. Both `release_year` columns need the explicit idempotent `PRAGMA table_info` + `ALTER TABLE` upgrade: `CREATE TABLE IF NOT EXISTS` never adds a column to an existing state DB.

- Disliking ("讨厌") is a **soft penalty, never an exclusion**, because the request was 少推荐这首歌 rather than 不要再推荐. `recommendation_feedback` gains a `DISLIKE`/`UNDISLIKE` pair `ORDER BY created_at DESC, id DESC` beside `LIKE`/`UNLIKE`, folded into one like/dislike axis by `Get-TrackPreferenceMapDb` (most recent wins) and `Get-LatestTrackPreferenceDb` (targeted, for per-track reads). Disliking writes an `UNLIKE` first and the `DISLIKE` second so the tie on a shared timestamp breaks on `id` and DISLIKE wins, which clears the heart without cancelling a download or deleting a file — `Write-TrackDislikeDb` is preference-only and never touches the wanted queue.

- Disliking a song down-weights **everything related to it**, not only that recording: the reported requirement was 和这首歌有关的都要降低推荐权重. Relations live in `dislike_relations (track_id, relation_type, relation_key)` — a **new table**, so `CREATE TABLE IF NOT EXISTS` adds it to an existing state DB and no `ALTER` path is needed (unlike a new column). The vocabulary is `TRACK`, `ARTIST`, `ALBUM`, `SIMILAR`, `SEED` in `$script:DislikeRelationOrder` (strongest first) and `Save-DislikeRelationsDb` refuses any type outside it, so a typo cannot create a bucket nothing reads. `Get-DislikeRelationBuckets` builds the TRACK bucket from the disliked row itself (never from storage), which is why a dislike takes effect on the very next run even before any expansion; `Get-CandidateDislikeRelation` returns the **single strongest** relation so one candidate is penalised once rather than stacking. ARTIST relations are per credited singer (`Split-LocalArtistNames`), so a duet `A,B` still relates a solo track by `B`. Relations are cached because the similarity lookup costs a network request: `Get-NeteaseSimilarSongs` is one bounded, circuit-charged call per disliked song, skipped once any SIMILAR relation exists, capped by `$dislikeLookupLimit`, and an **empty** answer is deliberately not latched so it retries later. Penalties are graded in `$DislikeRelationPenalty` (TRACK 5, ARTIST 3, ALBUM 2, SIMILAR 2, SEED 1, against a fresh candidate's 1–3 per seed) and, on the local source, `$DislikeRelationDivisor` (4/3/2/2/1) which `Select-LocalRecommendationTracks` applies via `-DislikeBuckets`/`-DislikeDivisors` **before** its `Sort-Object` — demoting after selection only reorders the picks already chosen. Undisliking leaves the cached rows in place but they go inert, because the buckets are built from currently-disliked songs only; `Get-DislikedTrackKeysDb` backfills title/artist/album/NetEase id from the canonical track so a dislike recorded before the relation existed still yields an ARTIST relation.

- **PowerShell 5.1's `ConvertFrom-Json -InputObject` nests a JSON array inside another array**, so `@(ConvertFrom-Json ...)` on a one-item array returned a *wrapper* rather than the items. Scalar member access hid it (member enumeration unwraps a one-element array) while property lookups did not, which is why `identifiers_json` "looked fine" but `Get-NeteaseIdFromTrack` returned `''` for **every** track read back from the database — measured 60/60 and 80/80 real rows. `ConvertFrom-MusicServerJsonArray` (Database module) is the single, strictly array-only reader: it wraps the text as `{"items":<text>}` before parsing, validates the text starts with `[`, and returns `@()`. `Invoke-MusicServerSqlJson`, `Convert-DbTrackRow` (`identifiers`/`preview_sources`/`download_candidates`), `Add-CanonicalTrackIdentifierDb`, the recommendation preview row, and both Navidrome row readers all go through it. Do **not** reintroduce a local flattening loop or a bare `ConvertFrom-Json -InputObject` on a JSON array column: the nesting is a parser quirk, and guessing at the shape instead of fixing the read is what let it survive.

- `tests/MusicServer.Web.Tests.ps1` must import `MusicServer.Providers.psm1`: it dot-sources `Get-UiLibrary` out of the launcher, and that function calls `Resolve-DisplayArtist`. Without the import the test failed with "Resolve-DisplayArtist is not recognized" — a pre-existing red that only surfaced locally because the suite is run one file at a time.

- Optional `MUSICSERVER_STARTUP_TRACE` writes a bounded desktop setup report and separate `.ui.json` / `.api.json` script-phase reports. Outputs use new files, never overwrite existing reports, and diagnostic failures do not block startup. Reports contain phase timings, not rendered UI readiness. Measurement disables downloads, scheduled-task registration and artist backfill in isolated APP homes; `Restart` excludes one warm-up and `FreshRuntime` stages into a new home per sample.
- The launcher keeps a 400 ms API preflight port probe. For its owned API child it probes immediately, with at most 100 ms per connect and 100 ms between probes under a 27-second monotonic readiness budget, and reports child exit before further waiting. Desktop build-identity checks and service ownership remain unchanged.

- Local artists are resolved rather than read. Bilibili downloads tag the **uploader** in `media_file.artist` and sit directly in the library root, so the index value is not the singer. `local_track_artists` (`path_key` normalized absolute path → `artist`/`album`/`status`/`source`) caches one outcome per file, including `NOT_FOUND`, so a library that cannot be resolved is not re-searched every start. The launcher's single-runspace `Start-ArtistBackfill` (`MUSICSERVER_ARTIST_BACKFILL_LIMIT`, `MUSICSERVER_DISABLE_ARTIST_BACKFILL=1`) fills it, `Get-UiLibrary` and the API's `Add-ResolvedArtist` overlay it onto every library response, and the list cache is invalidated when a pass completes. The launcher calls `Initialize-LocalTrackArtistSchema` explicitly because it binds an existing DB with `Connect-MusicServerDatabase`, which by design creates nothing.

- Artist lookup precision comes from a file-name gate, not from the search ranking. `Test-FileVouchesForArtist` accepts a NetEase candidate only when the file name already contains every artist it credits: searching a song name otherwise returns a different recording (`EXO-M` for `EXO-K《mama》`, `XG` for `Hearts2Hearts《RUDE!》`). Duration is a tie-breaker only, because uploads pad or extend the song (a 1540 s single-file upload of a 279 s track is still correct). `Get-TitleSearchKeywords` tries at most three keywords (bracketed song name first, then cleaned title) and `Resolve-NeteaseTrackArtist` charges each to the `netease` circuit, stopping as soon as the circuit refuses. `Get-TitleDeclaredArtist` supplies an offline fallback for what the lookup cannot resolve: the `<artist>《<song>》` convention, plus a guarded `Song - Artist` tail that is only trusted when neither side carries brackets, series or marketing noise — guessing wrong would display a song name as an artist, which is worse than showing none.

- `Resolve-DisplayArtist` is the single display decision and both overlays (launcher `Get-UiLibrary`, API `Add-ResolvedArtist`) go through it. A cached `netease` match is final and reused; a `source = 'title'` value costs no network call and is therefore **recomputed on every read**, so improved parsing rules heal rows an older build already wrote with no migration. When the rules now refuse a title, the indexed value stays rather than being blanked. Channel branding is a prefix shared by many titles (`Get-SharedTitlePrefixes` / `Remove-SharedTitlePrefix`), so it is detected from the whole set and stripped only when it ends on a boundary character — otherwise a repeated real artist name (`许嵩《…》` four times) would be deleted as if it were branding. A declared name must also be a single credit: CJK text mixing spaces, or a long CJK run with no separator, is a comment or branding, while a Latin credit may still contain spaces (`Alan Walker&Sabrina Carpenter&Farruko`). The sentence/bracket rejection must run **before** trailing-punctuation cleanup, which would otherwise erase the `！` in `仙气空灵！` that proves the text is a comment.

- `local_track_artists.updated_at` must be produced by `Get-NowIso` before the SQL template is expanded. Templates expand parameters as literals, so passing the bare command name stores it verbatim and silently breaks the 30-day retry window.

- The library has **two display modes**, chosen in 设置 and stored in `app_settings.library_display_mode` (`Get-LibraryDisplayModeDb` / `Set-LibraryDisplayModeDb`, `GET`/`PUT /api/settings/display-mode`). **传统模式 (`raw`) is the default** and shows the folder's own truth: the file name verbatim and the indexed singer (for a Bilibili download, the uploader), with no album and no year. **正则模式 (`canonical`, Beta)** shows `cleanSongName(title)` plus the resolved singer, album and NetEase release year. The mode is a *rendering* choice, so the data layer must never destroy either vocabulary: both overlays (`Get-UiLibrary`, `Add-ResolvedArtist`) capture `raw_artist`/`raw_album` before the resolution loop overwrites `artist`/`album`, and `title`/`name` stays raw. `formatTrackDisplay` is the single mode-aware decision — library rows, 我的常听, the player bar and recommendation rows all read `display.title/artist/album/year` from it, so an unreadable settings API keeps `raw` instead of silently regularizing names. Search indexes both vocabularies (`title`/`name`/`artist`/`raw_artist`/`album`/`raw_album`), so the same row is findable in either mode. Switching modes re-renders only; it never rescans and never restarts a service.

- A `<series>ost` label in front of the song name is a label, not a singer. `Get-TitleCreditAfterSeriesLabel` returns everything after the last `ost`/`ep`/`op`/`ed` token, and `Get-TitleDeclaredArtist` uses it before the "CJK with spaces" refusal — that refusal was not neutral, because the caller then fell back to the indexed artist and displayed the Bilibili uploader (`JLRS-LeoFM`) for `爱情公寓3ost 陈韵若&陈每文《爱的回归线》`. Only a token carrying CJK text or the bare marker counts, so a performer whose name merely ends in those letters is untouched; measured over the real 172-title library, exactly 5 rows change and every one of them went from *no artist* to the correct singer.

- `cleanSongName` (web) must not pick an artist credit as the song name. `×`/`＆`/`&` on one side of a `Song - Artist` split marks that side as a credit list (`音阙诗听×李佳思 - 流浪的猫写情诗`), and a `·` tail that reads as a descriptor is a subtitle (`流浪的猫写情诗·甜到掉牙的`). The dot rule only fires on a segment no bracket settled, so a quoted real title keeps its dot (`陈彼得《青玉案·元夕》` must stay `青玉案·元夕`); its head is added as a *strong* candidate so the pool filter evicts the full run.

- Hermetic runtime fixtures (`MusicServer.RuntimeFixture.ps1`, `MusicServer.UiProxyRuntime.Tests.ps1`) set `MUSICSERVER_DISABLE_ARTIST_BACKFILL=1` for the child launcher. Without it the background resolution reaches the network inside socket regressions and the suite stalls rather than failing.

- The library read path must not filter on Navidrome's `missing` column. That column is only refreshed by a Navidrome scan, and the packaged runtime never installs or runs Navidrome, so every row stays flagged `missing = 1` and `WHERE missing = 0` returns nothing. The launcher and the API now select all rows and require `[IO.File]::Exists` on the resolved path instead; `Get-LibraryFolderArtist` returns empty when a file's parent is the library root itself, so a flat library can no longer report the library name as every artist. `tests/MusicServer.ArtistResolution.Tests.ps1` covers the resolver and the gate; `tests/MusicServer.Web.Tests.ps1` pins the no-`missing`-filter and file-existence behavior. The same mistake existed a second time in `daily_recommend.ps1`'s library-seed query, so every seed silently degraded to a bare `.mp3` basename with no artist; it now reads `Get-LocalLibraryRows`, which keeps the resolved singer and the library id per row.

- Recommendations have two sources, and the split is deliberate. NetEase (`Search-Netease` + `Get-SimiSongs`) is discovery: every online candidate is a track the user does not own, and it is the only path that produces `netease` ids. The local source (`Get-LocalArtistAffinity` + `Select-LocalRecommendationTracks`, `seed_source = 'local_library'`) answers the opposite question — which owned tracks to hear again — and is **preference-led, not library-led**: a track is eligible only when the listener has already shown interest in that artist (explicit positives weight 6, play counts `min(plays, cap) * 2`), so a large untouched library cannot turn the day into a dump of its own files. A local pick must carry a library id, because playback resolves through the index and a file on disk but absent from it would be recommended as something unplayable. Picks are one-per-artist, least-recently-played first, skip anything played within 14 days, and are appended after the online picks under `-LocalCount` (**default 0: the daily push is remote-only**; a positive value opts into local re-listens). Exclusion keys must be normalized on **both** sides: comparing a normalized lookup against raw keys silently failed for any key normalization rewrites (a library id containing a hyphen).

- `Get-SongSearchQueries` builds the NetEase query from a library track: the cleaned song name with the resolved lead artist first, then alone. Seeding with the raw uploader title wastes the lookup, and appending an artist the keyword already names (`陈奕迅 陈奕迅`, `Roselia Always recall. Roselia`) produces a string more specific than any real NetEase title, so it can never match. The search only accepts a candidate whose song name matches the query, which is a second precision gate beside `Test-FileVouchesForArtist`.

- A preview's `provider` must come from the `preview_sources` record, never be assumed: `Get-TrackPlaybackSource` reported a NetEase preview URL as `bilibili`, which misleads any caller that branches on the provider.

- Runtime logging: `Write-MusicServerLog` (bounded at 4 MB, keeps `.1`/`.2`) is the single sink under `APP_HOME\logs`. The launcher, the watchdog, the API (`musicserver-api.log`: startup, per-request line, `ERROR`, `SLOW` ≥ 3 s) and the worker (`musicserver-worker.log`: pass start, candidate choice, download/validation outcome, retry reasons) all log through it; per-poll keep-alive lines stay console-only. Previously only the launcher wrote a file, so API/worker diagnostics were silently discarded.

- Download success rate: `Test-ProviderRequestAvailable` now reports `HALF_OPEN` as available so the single allowed probe is actually claimed (`Claim-ProviderRequest` -> `Claim-HalfOpenProbeDb` keeps exclusivity); the previous `probe_pending` check deadlocked the circuit. `Search-NeteaseCandidate` adds a bounded NetEase discovery fallback for tracks without a NetEase id: at most one search per resolve, charged to the `netease` provider circuit, only when no local/direct candidate exists, disabled with `MUSICSERVER_DISABLE_NETEASE_SEARCH=1`. A discovered id is persisted through `Add-CanonicalTrackIdentifierDb`. `UNAVAILABLE` stays terminal; the 下载动态 panel renders an explicit 重试 action for `UNAVAILABLE`/`RETRY_WAIT` rows.

- The desktop runtime ships `daily_recommend.ps1`, `register_daily_recommend.ps1` and their `MusicServer.Migration.psm1` dependency. All three are staged by `scripts/prepare_tauri_runtime.ps1`, listed in the Rust runtime `REQUIRED` allowlist and included in the content build identity; `daily_recommend.ps1` takes `-AppHome` so a scheduled run is independent of environment variables. The launcher registers `MusicServer_DailyRecommend` (daily 07:00, action bound to the packaged APP_HOME) idempotently. Registration is skipped for source checkouts (`.git` present) and disabled with `MUSICSERVER_DISABLE_SCHEDULED_TASKS=1`; failures are logged and never block startup. `MusicServer_DailyCleanup` is still a legacy manual task and is not auto-registered.

- A fresh install must produce recommendations with no manual setup, which needs three things that were all previously missing. (1) `register_daily_recommend.ps1` passes `New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable` (1-hour limit, `IgnoreNew`); plain `Register-ScheduledTask` defaults refuse to start on battery and never catch up a 07:00 trigger missed while the PC was off, so laptop users silently got nothing. (2) The launcher repairs a task whose settings are stale through `Test-DailyRecommendTaskCurrent` instead of trusting the action path alone, so already-installed builds recover on the next start. (3) `Get-RecommendationSeedCandidatesDb -LibraryFallback` seeds from the local library **only when the preference pool is empty**, and `daily_recommend.ps1` reads it from a copy of the Navidrome DB (or `.mp3` basenames) — otherwise a user with no likes, stars or legacy import has zero seeds and the generator still "saves" an empty day. Backfill is keyed on `Test-DailyRecommendGeneratedToday` (any `daily_recommendations` row for today) rather than the last run time, so a run that failed mid-way is retried while a completed day is not regenerated on every APP start; a run that started within the last 15 minutes is left alone. The health check and the registration both take the launcher's resolved `-AppHome` (see the APP_HOME pin bullets below) instead of `$Root`, because the directory the scripts live in and the home the state lives in are two different things. Verified end-to-end against the staged runtime in a simulated install directory: no `.git`, no `MUSICSERVER_APP_HOME`, empty day -> task registered, backfill started, packaged generator produced rows from `library_fallback`.

- `MusicServer_DailyRecommend` follows the user rather than freezing install-time state. `Get-DailyRecommendTaskPreferences` reads the trigger time and `-Count` back from the task being replaced, so a repair caused by a moved install directory, a reinstall, or stale settings written by an older build keeps the schedule the user chose instead of resetting it to 07:00 / 20. The task stores only `-AppHome`; the music library is resolved at run time by `daily_recommend.ps1` through `Apply-ConfiguredMusicDir` and `$Config.MusicDir`, so changing the library in 设置 needs no task change. A source-checkout launcher running against a packaged APP_HOME rewrites the action to that home on the next start, which is why the launcher log shows one re-registration after installing over an older build.

- Installed smoke restart checks the actual APP process exit and then requires all service ports closed. A nonzero taskkill tree result is diagnostic only after confirmed APP exit; it must never bypass the process/port shutdown gates. PS5.1 Tauri tests cover this distinction.

- Desktop launches PowerShell and taskkill through `background_process::command` with Windows CREATE_NO_WINDOW and disconnected standard handles. PowerShell also uses NonInteractive; do not rely on WindowStyle Hidden alone, which can briefly allocate a console. The Rust regression queries GetConsoleWindow inside a real child process. Release builds retain the Windows GUI subsystem.

- Runtime manifests use schema 2 with per-file size/SHA-256 and content build identity. Desktop validates required files, managed paths, duplicate names, hashes and reparse points before modifying APP home. Changed files are fully written and synced in APP home before individual rename replacement; this is not a whole-runtime transaction or schema rollback.
- Runtime source identity is computed by MusicServer.Identity.psm1 from sorted relative names and SHA-256 content hashes. Rust embeds the same digest at build time; UI/API cache it at process startup. Machine paths and user state are excluded. Source changes therefore cannot relabel an already running service. MUSICSERVER_DISABLE_WORKER=1 explicitly disables the downloader for isolated EXE measurements; normal startup is unchanged.

- Desktop identity probes have a 1.2-second total network deadline and a 1 MiB response cap. Only a completed HTTP 200 response with the marker in its body is accepted; declared Content-Length must match. Each launched port pair has a 30-second readiness budget including network probes and sleeps. Rust TCP regressions run in the existing desktop gate. These bounds do not cover runtime staging/process teardown or establish faster normal startup.

- `tests/run_suite.ps1` pins Pester 3.4.0, excludes RequiresLocalRuntime by default, and reports failures from TestResult (name, message and stack). Exit codes are 0/1/2/3 for pass/test failure/runner error/timeout; zero discovered tests is an error. The state CI group includes TestRunner subprocess regressions; the suite index is tests/README.md.

- The UTF-8-BOM rule is now **asserted, not trusted**: `tests/MusicServer.TestRunner.Tests.ps1` fails and names the file when any tracked `.ps1`/`.psm1` outside `artifacts`/`target`/`node_modules` carries non-ASCII bytes without a BOM. PS5.1 decodes a BOM-less script with the ANSI code page, so CJK in a test name, assertion or fixture becomes mojibake that differs between CI (CP1252) and a Chinese workstation (CP936) — a locale-dependent red, not a visible syntax error. This is how a BOM-stripping edit ships unnoticed: an editing tool that rewrites a file can drop the BOM while leaving the text intact, and `.editorconfig` is not consulted by every tool. Four files lost their BOM this way in one change and were restored.

- Do **not** pass a relative path to a `[IO.File]`/`[IO.Path]` static call in a test or helper. .NET resolves it against the **process** current directory, which is not PowerShell's location: a shell that `cd`s into a worktree still writes to whatever directory the host process started in. One `[IO.File]::WriteAllBytes('tests/...')` aimed at a worktree silently targeted the live checkout instead (harmless only because the file already had a BOM). Always build the path from `$PSScriptRoot`/`Get-Location` or an absolute root before handing it to a .NET API.

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

- APP_HOME needs a **machine pin**, because an environment variable cannot be the only locator. The Tauri installer ends by starting the APP through `nsis_tauri_utils::RunAsUser` (tauri-bundler's `installer.nsi`, `Function RunMainBinary`), which reaches the app **without** the invoking session's environment. Two observed launches were installer-borne and both fell back to the default home (9/10 20:11 and 9/12 08:52), each time creating a second, empty state home — the UI served a working library next to an empty 今日推荐 while the 07:00 task wrote into the other home. Resolution order is now `MUSICSERVER_APP_HOME` -> **`HKCU\Software\MusicServerRuntime` value `AppHome`** -> `%LOCALAPPDATA%\com.musicserver.desktop`, implemented twice on purpose: Rust (`resolve_app_home` over the pure `pick_app_home`, unit-tested) and PowerShell (`Get-MusicServerPinnedAppHome` + `Resolve-MusicServerAppHome`). The pin key is deliberately **not** under `HKCU\Software\<manufacturer>\<product>` or `%APPDATA%\<bundle id>`, both of which the NSIS uninstaller deletes, so a reinstall cannot lose it. Set it with `scripts/maintenance/set_app_home_pin.ps1 -AppHome <dir>` (fail-closed: a mistyped path would silently become a new empty home). `MUSICSERVER_APP_HOME_PIN_KEY` relocates the lookup, and `tests/run_suite.ps1` points it at a nonexistent key so a suite that forgets `MUSICSERVER_APP_HOME` can never write into live state — which also means a suite started with a bare `Invoke-Pester` **does** see the host machine's pin.

- The service tree must resolve **one** home. `start_musicserver_ui.ps1` takes `-AppHome`, exports the resolved value as `MUSICSERVER_APP_HOME` before spawning the API/worker/generator (each resolves APP_HOME itself), and Rust passes `-AppHome <home>` plus that same variable to the launcher. Without this the launcher could serve one home while the API read another.

- A missing day must self-heal, and the scheduled task must not be able to prevent that. `Test-DailyRecommendTaskCurrent` now also compares the action's `-AppHome` against the resolved home: a task bound to another home generates a day this APP never reads, and its `LastRunTime` is not evidence about *this* home. Task registration and the backfill are separate failure domains — `Register-ScheduledTask` returns `Access is denied` for an unelevated APP, and while both shared one `try` block that exception aborted the backfill too, leaving `Scheduled task setup skipped: Access is denied.` as the only trace. A missing `register_daily_recommend.ps1` is treated the same way (it throws inside that block instead of returning early), because "the task cannot be registered" must never mean "skip the day". The fallback `Start-MusicServerDailyRecommendBackfill` runs `daily_recommend.ps1` directly (detached, output redirected to `<APP_HOME>\logs\musicserver-daily.*.log`) and is leased through `DailyMix_data\state\daily_recommend.lease` (15 minutes) so a watchdog restart cannot stack generators on one day. Verified end-to-end on a staged runtime whose registrar was removed: `WARN daily recommendation task repair failed: registrar is missing`, then `Started daily recommendation generator directly`, then 20 rows in that home's DB and none of them local.

- `%LOCALAPPDATA%\com.musicserver.desktop\EBWebView` keeps changing even when APP_HOME is pinned elsewhere, and that is **not** the split brain coming back: it is the Tauri shell's WebView2 user-data folder, which the webview derives from the bundle identifier rather than from APP_HOME and which holds the UI's `localStorage` (play mode, library sort/order, collapsed panel). The check for the old failure is the *state* home — `DailyMix_data\state\musicserver.db`, `logs\`, `Music\`, `Navidrome\` — whose timestamps must stay frozen once the pin is in place. Relocating the webview profile would reset those UI preferences, so it is not done silently.

- The daily push is **remote-only by default**: `daily_recommend.ps1 -LocalCount` defaults to `0`, so a song the listener already owns is not part of 今日推荐. The local re-listen source (`Select-LocalRecommendationTracks`, `seed_source = 'local_library'`) is unchanged and remains an explicit opt-in.

- Minimize-to-tray is a **window behavior, not a second exit path**. The close button X keeps its meaning: `WindowEvent::Destroyed` still stops the launcher/service tree this APP owns, and it must not be turned into a hide. Only minimize hides the window (there is no `Restore`/`Exit` tray menu and no close-to-tray). Tauri v2 has **no minimized window event** — a minimize arrives as `WindowEvent::Resized` — so the state is read from the window with `window.is_minimized()` instead of being inferred from the event, and a plain resize/maximize/restore must not hide anything. Hiding has one hard precondition: the tray icon must actually exist (`app.tray_by_id(TRAY_ID)`), because the tray is the only way back and a hidden window with no tray disappears from both the taskbar and the notification area — exit would then require killing the process. `should_hide_to_tray(minimized, tray_available)` is that decision as a pure, unit-tested function. The icon is built in `setup` by `install_tray_icon` from `tauri`'s `tray-icon` feature (tauri 2.11.5 already resolves `tray-icon`/`muda`, so **no new crate versions**; the tray reuses `bundle.icon`'s `icons/icon.ico`, which codegen embeds as `default_window_icon` on Windows), left-click restores with `unminimize` + `show` + `set_focus` (unminimize first: the hidden window is still minimized, so a bare `show` would leave an empty minimized window on the taskbar), and a failed creation is recorded as `tray_icon_unavailable` in the startup trace and degrades to normal minimize. `tests/MusicServer.Tauri.Tests.ps1` pins this contract; the actual minimize/click interaction is desktop-only and is not covered by a headless suite.

- Canonical (正则) mode cuts the row's **own singer** out of a title, because that is the only reliable way to tell a credit from a song. Two real shapes needed it: a credit glued with a bare `-` (`光年之外-G.E.M.邓紫棋` — the CJK/Latin dash rule deliberately never splits that) and a credit in front of a short song name (`周杰伦 - 七里香`, where a three-character song and a three-character singer tie on candidate score and candidate order decided, so the *singer* was displayed as the song). `stripSingerCredit(rawTitle, singer)` removes only a whole segment that **is** the singer — `EXO-K` (Latin-Latin, never split), `Beyond《冷雨夜》…` and a duet credit `周杰伦&费玉清 - 千里之外` are untouched — and takes the separator that joined it along; `TAIL_MARKER_RE` then turns a leftover trailing `live`/`cover` into the existing `(Live)`/`(Cover)` suffix. The singer column still carries the name (both modes), so a regularized title must not repeat it. Measured over the live 172-row library, exactly 6 canonical titles change and all six are corrections (two of them previously showed the singer name *as* the song). Traditional (raw) mode is untouched: it still shows the file name verbatim, which is why a library whose file names already embed the singer looks inconsistent until the mode is switched.

- Releases are **signed with a self-signed code-signing certificate**, because an unsigned installer makes Windows ask for confirmation on every download (the installer's manifest is `asInvoker`, so this is SmartScreen / browser reputation, not UAC). `scripts/signing/New-MusicServerSigningCert.ps1` creates the certificate idempotently, exports the public `scripts/signing/MusicServer-CodeSigning.cer` (committed, so another machine can import trust without rebuilding) and imports trust into `LocalMachine\TrustedPublisher` + `LocalMachine\Root` when run elevated; `scripts/signing/Sign-MusicServerArtifact.ps1 -Path <artifact>` signs with `signtool` (located in the Windows SDK; `Set-AuthenticodeSignature` is the fallback) and reports `Valid`, a status a self-signed certificate only reaches once it is trusted on that machine. Signing is a **post-build step and is not wired into `tauri.conf.json`**, so a build on a machine or CI runner without the certificate warns and stays unsigned instead of failing; pass `-RequireSignature` when a release must be signed. A self-signed certificate cannot remove Microsoft's reputation-based "不常见的下载" warning on machines that never imported it — only a purchased certificate can.
