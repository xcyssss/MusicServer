# MusicServer - Agent Guide

Local music server: Bilibili audio downloads + Navidrome streaming + automated daily recommendations.

Git repo. Branches: `main` (released), `review/musicserver-hardening-v1`, `review/musicserver-hardening-v2` (active — SQLite as sole runtime truth + atomic API transactions).

## Stack

- **PowerShell modules** — `MusicServer.Core` / `.Database` / `.State` / `.Migration` / `.Providers` / `.DesiredStateWorker`
- **music_api.ps1** — HTTP listener on `http://127.0.0.1:8787/`, front-end agnostic JSON API
- **src-tauri/** — Tauri v2 Windows desktop shell; the primary client is the packaged APP
- **web/** — `index.html` + `app.js` + `styles.css`, the shared WebView2 UI loaded by the Tauri APP at `http://127.0.0.1:8790/` (not a separate browser product)
- **SQLite** — sole runtime source of truth. JSON files are migration input / backups only
- **Navidrome** v0.63.2 — music server, Subsonic-compatible, runs as Windows service or standalone
- **yt-dlp** — Bilibili audio extraction (via `C:\Users\dell\anaconda3\Scripts\yt-dlp.exe`)
- **ffmpeg/ffprobe** — transcoding, tag rewriting, duration validation (`C:\Users\dell\AppData\Local\Microsoft\WinGet\Links\ffmpeg.exe`)
- **sqlite3** — direct queries against `Navidrome\Data\navidrome.db` (starred tracks, library state)
- **PowerShell** — all scripts are `.ps1`, run from `E:\Project\MusicServer`

## Key paths

```
E:\Project\MusicServer/
  Music/                      # Main library (mp3 + lrc pairs)
  Music/DailyMix/             # Today's recommendations (auto-cleaned)
  Navidrome/bin/navidrome.exe # Server binary
  Navidrome/navidrome.toml    # Config (port 4533, MusicFolder, ffmpeg path)
  Navidrome/Data/navidrome.db # SQLite database (DO NOT edit while server runs)
  DailyMix_data/              # Recommendation state (today.csv, history.csv, accepted.csv, rejected.csv)
  cookies.txt                 # Bilibili auth cookie (expires, refresh manually)
  lyrics_report.csv           # Lyrics matching report
  src-tauri/                  # Tauri v2 desktop shell and release build configuration
```

## Scripts

| Script | Purpose | Key params |
|--------|---------|------------|
| `download_bilibili_favorites.ps1` | Bulk download Bilibili favorites | `-FavoritesUrl`, `-CookieFile` |
| `add_song.ps1` | Interactive single-video downloader | Paste BV URLs at prompt |
| `daily_recommend.ps1` | Daily 30-song recommendation pipeline | `-DryRun`, `-Count`, `-SeedCount` |
| `daily_cleanup.ps1` | Keep ♥'d songs, blacklist the rest | `-DryRun`, `-KeepDays` |
| `fetch_lyrics.ps1` | Batch LRC lyrics from NetEase | `-DryRun`, `-Force`, `-Filter`, `-Limit` |
| `fix_one_lyric.ps1` | Manual lyric fix for one song | `-FilePattern`, `-SongId` or `-Search` |
| `fix_tags.ps1` | Rewrite ID3 tags, set album="B站收藏" | None |
| `start_navidrome.ps1` | Start server (service or standalone) | `-Port`, `-NoBrowser` |
| `lib_playlist.ps1` | Shared m3u writer (sourced by recommend/cleanup) | N/A (dot-sourced) |
| `music_api.ps1` | HTTP API server (v2) | `-Prefix`, `-Once`, `-Root` |
| `wanted_worker.ps1` | Background download worker | see module docs |
| `start_musicserver.cmd` / `.vbs` | Launch API + worker hidden | None |
| `tests/verify_tauri_desktop.ps1` | Tauri APP process/HTTP/playback/shutdown smoke verifier | `-Launch`, `-ExercisePlayback`, `-CloseLaunchedApp` |

## Tests & CI

Formal suites live in `tests/` and are named `MusicServer.*.Tests.ps1` (Pester 3.4, Windows PowerShell 5.1-compatible). Anything else in `tests/` is a throwaway probe and is git-ignored.

```powershell
Import-Module Pester -RequiredVersion 3.4.0 -Force
Invoke-Pester .\tests\MusicServer.Core.Tests.ps1 -PassThru
```

CI (`.github/workflows/core-tests.yml`, windows-latest + Windows PowerShell 5.1) runs on push to `main` and `review/**`. It splits suites across two parallel jobs so neither hits the job timeout:

| Job | Suites |
|-----|--------|
| `state` | Core, Database, V2, WorkerConcurrency, Web, Tauri |
| `api` | ApiTransaction, ApiRuntime |

Measured locally on PS 5.1: ApiTransaction ≈ 334s, ApiRuntime ≈ 152s, the other four ≈ 480s combined. Serial is ~16 min, so keep the split.

Two things CI needs that a fresh runner does not have:

- **sqlite3** — `MusicServer.Database.psm1` resolves `sqlite3.exe` from PATH with no fallback path. CI installs it via `choco install sqlite`. Without it every DB-backed suite fails.
- **Pester 3.4.0** — installed on demand from PSGallery.

Suites that assert against a **live** MusicServer (running API, local library, `lyrics_report.csv` — the latter two are git-ignored) must be tagged `RequiresLocalRuntime`; CI passes `-ExcludeTag RequiresLocalRuntime`. Run them locally with:

```powershell
Invoke-Pester .\tests\MusicServer.Web.Tests.ps1 -PassThru   # includes the tagged Describe
```

Diagnostic scratch output goes to `artifacts/` (git-ignored). Do not commit it.

## Automated schedule

Two Windows scheduled tasks run daily:

| Task | Time | What it does |
|------|------|--------------|
| `MusicServer_DailyCleanup` | 06:30 | Reads Navidrome starred status; keeps ♥'d songs in main library, deletes others, updates rejected.csv blacklist |
| `MusicServer_DailyRecommend` | 07:00 | Seeds from library + accepted.csv, queries NetEase for similar songs, downloads from Bilibili, writes lyrics |

Both run as `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <script>`.

## Data flow

```
library.mp3 + accepted.csv  -->  NetEase simiSong API  -->  Bilibili search/download
                                                              |
                                                         Music/DailyMix/
                                                              |
                                                    Navidrome auto-scans (6h)
                                                              |
                                                    User hearts or ignores
                                                              |
                                               next morning: daily_cleanup
                                                    /                \
                                            ♥ -> move to Music/    no ♥ -> delete + blacklist
                                            accepted.csv           rejected.csv
```

## Gotchas

- **cookies.txt expires** — when downloads fail with "Unable to extract JSON", re-export from browser
- **Bilibili rate limits (HTTP 412)** — scripts retry up to 3x with increasing delays; `--sleep-requests` and `--http-chunk-size 1M` help
- **Navidrome DB locking** — scripts copy the DB to a temp file before querying sqlite3; never edit navidrome.db directly while server is running
- **Lyrics are external .lrc files** — Navidrome reads them in real-time, no scan needed after adding. Priority: `.lrc` > `.txt` > embedded tags (see `navidrome.toml` `LyricsPriority`)
- **Duration validation** — `daily_recommend.ps1` discards downloads where local duration differs from NetEase metadata by >45s (wrong video matched)
- **Desktop APP is the product target** — validate UI behavior through the Tauri APP. The APP is a WebView2 shell over `web/`; do not replace the shared UI with a second Rust/native UI or treat browser-only checks as desktop acceptance.
- **Stale desktop services** — Tauri verifies the `web/app.js` and API `/health` build marker before reusing 8790/8787; if another build owns those ports it uses an isolated fallback pair. `start_musicserver_ui.ps1` accepts `-ApiPrefix` and `-UiPrefix` for that reason.
- **File names are the metadata** — Bilibili titles are noisy (UP主 names, quality tags, etc). `fetch_lyrics.ps1` strips these via `$NoiseWords` list before searching
- **m3u playlists auto-import** — Navidrome watches Music/ for .m3u files; `lib_playlist.ps1` writes relative paths and UTF-8 no-BOM

## Common operations

```powershell
cd E:\Project\MusicServer

# Download favorites (needs fresh cookies)
.\download_bilibili_favorites.ps1 -FavoritesUrl "https://www.bilibili.com/medialist/detail/ml..." -CookieFile ".\cookies.txt"

# Dry-run daily recommendation (see what would be downloaded)
.\daily_recommend.ps1 -DryRun

# Run daily recommendation now
.\daily_recommend.ps1

# Dry-run cleanup (see what would be kept/deleted)
.\daily_cleanup.ps1 -DryRun

# Batch fetch lyrics (preview first)
.\fetch_lyrics.ps1 -DryRun
.\fetch_lyrics.ps1 -Force          # overwrite existing .lrc files
.\fetch_lyrics.ps1 -Filter "*Roselia*"  # only process matching files

# Fix a single song's lyrics
.\fix_one_lyric.ps1 -FilePattern "*若月亮还没来*" -Search "若月亮还没来"
# Then pick the right SongId from output:
.\fix_one_lyric.ps1 -FilePattern "*若月亮还没来*" -SongId 1974443814

# Check library state
sqlite3 Navidrome\Data\navidrome.db "select count(*) from media_file;"
sqlite3 Navidrome\Data\navidrome.db "select count(*) from annotation where starred=1 and item_type='media_file';"
```

## Navidrome config notes

- Port: 4533, bound to 0.0.0.0 (LAN accessible)
- Scanner: auto every 6 hours
- Auto-import m3u playlists enabled
- Lyrics priority: `.lrc` first
- Data folder: `Navidrome/Data/` (DB, cache, scanner logs)
