# MusicServer - Agent Guide

Local music server: Bilibili audio downloads + Navidrome streaming + automated daily recommendations. Not a git repo.

## Stack

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
