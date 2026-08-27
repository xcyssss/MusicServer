# Bç«™æ”¶è—å¤¹ â†’ Navidrome éŸ³ä¹æœåŠ¡å™¨ å®Œæ•´æ•™ç¨‹

## ç›®å½•ç»“æ„

```
E:\Project\MusicServer\
â”œâ”€â”€ Music\                          â† éŸ³ä¹æ–‡ä»¶å­˜æ”¾å¤„
â”œâ”€â”€ Navidrome\
â”‚   â”œâ”€â”€ bin\navidrome.exe           â† Navidrome ç¨‹åº
â”‚   â”œâ”€â”€ navidrome.toml              â† é…ç½®æ–‡ä»¶
â”‚   â”œâ”€â”€ navidrome.log               â† æ—¥å¿—æ–‡ä»¶
â”‚   â””â”€â”€ Data\                       â† æ•°æ®åº“å’Œç¼“å­˜
â”œâ”€â”€ download_bilibili_favorites.ps1 â† Bç«™ä¸‹è½½è„šæœ¬
â””â”€â”€ start_navidrome.bat             â† å¯åŠ¨è„šæœ¬
```

---

## ç¬¬ä¸€é˜¶æ®µï¼šç¯å¢ƒå‡†å¤‡ï¼ˆå·²å®Œæˆ âœ…ï¼‰

| ç»„ä»¶ | çŠ¶æ€ | ä½ç½® |
|------|------|------|
| yt-dlp | âœ… å·²å®‰è£… v2026.07.04 | C:\Users\dell\anaconda3\Scripts\yt-dlp.exe |
| ffmpeg | âœ… å·²å®‰è£… | C:\Users\dell\AppData\Local\Microsoft\WinGet\Links\ffmpeg.exe |
| Navidrome | âœ… å·²ä¸‹è½½ v0.63.2 | E:\Project\MusicServer\Navidrome\bin\navidrome.exe |
| é…ç½®æ–‡ä»¶ | âœ… å·²åˆ›å»º | E:\Project\MusicServer\Navidrome\navidrome.toml |
| ä¸‹è½½è„šæœ¬ | âœ… å·²åˆ›å»º | E:\Project\MusicServer\download_bilibili_favorites.ps1 |
| å¯åŠ¨è„šæœ¬ | âœ… å·²åˆ›å»º | E:\Project\MusicServer\start_navidrome.bat |

---

## ç¬¬äºŒé˜¶æ®µï¼šè·å– Bç«™ Cookieï¼ˆä½ éœ€è¦æ‰‹åŠ¨æ“ä½œï¼‰

yt-dlp ä¸‹è½½æ”¶è—å¤¹éœ€è¦ä½ çš„ Bç«™ç™»å½• Cookieï¼Œç”¨äºéªŒè¯èº«ä»½ã€‚

### æ­¥éª¤ï¼š

1. **å®‰è£… Cookie å¯¼å‡ºæ’ä»¶**
   - Chrome/Edge: å®‰è£… [Get cookies.txt LOCALLY](https://chromewebstore.google.com/detail/get-cookiestxt-locally/cclelndahbckbenkjhflpdbgdldlbecc)
   - Firefox: å®‰è£… [cookies.txt](https://addons.mozilla.org/firefox/addon/cookies-txt/)

2. **åœ¨æµè§ˆå™¨ä¸­ç™»å½• Bç«™** (https://www.bilibili.com)
   - ç¡®ä¿ä½ å·²ç»ç™»å½•å¹¶ä¸”èƒ½çœ‹åˆ°ä½ çš„æ”¶è—å¤¹

3. **å¯¼å‡º Cookie**
   - ç‚¹å‡»æµè§ˆå™¨å³ä¸Šè§’çš„æ’ä»¶å›¾æ ‡
   - é€‰æ‹© "Export" / "å¯¼å‡º"
   - ä¿å­˜ä¸º `cookies.txt`ï¼Œæ”¾åˆ° `E:\Project\MusicServer\cookies.txt`

4. **è·å–æ”¶è—å¤¹ URL**
   - æ‰“å¼€ä½ çš„æ”¶è—å¤¹é¡µé¢
   - URL ç±»ä¼¼: `https://www.bilibili.com/medialist/detail/ml1234567890`
   - å…¶ä¸­ `ml1234567890` å°±æ˜¯ä½ æ”¶è—å¤¹çš„ç¼–å·

---

## ç¬¬ä¸‰é˜¶æ®µï¼šä¸‹è½½æ”¶è—å¤¹éŸ³é¢‘

### åŸºæœ¬å‘½ä»¤ï¼ˆä½¿ç”¨è„šæœ¬ï¼‰

```powershell
# åœ¨ PowerShell ä¸­è¿è¡Œ
cd E:\Project\MusicServer

# ä¸‹è½½æ”¶è—å¤¹ï¼ˆéœ€è¦æ›¿æ¢ä¸ºä½ çš„æ”¶è—å¤¹ URLï¼‰
.\download_bilibili_favorites.ps1 `
    -FavoritesUrl "https://www.bilibili.com/medialist/detail/mlä½ çš„æ”¶è—å¤¹ç¼–å·" `
    -CookieFile "E:\Project\MusicServer\cookies.txt"
```

### å¸¸ç”¨æ“ä½œ

```powershell
# æŸ¥çœ‹ä¸‹è½½äº†å¤šå°‘æ–‡ä»¶
Get-ChildItem "E:\Project\MusicServer\Music" -Filter *.mp3 | Measure-Object | Select-Object Count

# æŸ¥çœ‹ä¸‹è½½çš„æ–‡ä»¶
Get-ChildItem "E:\Project\MusicServer\Music" | Select-Object Name, @{N='Size(MB)';E={[math]::Round($_.Length/1MB,1)}}

# åªä¸‹è½½å‰ 10 ä¸ªè§†é¢‘ï¼ˆæµ‹è¯•ç”¨ï¼‰
# åœ¨è„šæœ¬å‘½ä»¤ååŠ  --playlist-end 10
```

### åªä¸‹è½½å•ä¸ªè§†é¢‘çš„éŸ³é¢‘

```powershell
yt-dlp --extract-audio --audio-format mp3 --audio-quality 0 `
    --embed-thumbnail --embed-metadata `
    --cookies "E:\Project\MusicServer\cookies.txt" `
    -o "E:\Project\MusicServer\Music\%(title)s.%(ext)s" `
    "https://www.bilibili.com/video/BVxxxxxxxx"
```

### åªä¸‹è½½æ”¶è—å¤¹ä¸­æ–°å¢çš„æ­Œæ›²

yt-dlp ä¼šè‡ªåŠ¨è·³è¿‡å·²ä¸‹è½½çš„æ–‡ä»¶ï¼ˆ`--no-overwrites`ï¼‰ï¼Œ
ç›´æ¥é‡æ–°è¿è¡Œä¸‹è½½è„šæœ¬å³å¯åªä¸‹è½½æ–°å¢å†…å®¹ã€‚

---

## ç¬¬å››é˜¶æ®µï¼šå¯åŠ¨ Navidrome æœåŠ¡å™¨

### æ–¹å¼ä¸€ï¼šæ‰‹åŠ¨å¯åŠ¨ï¼ˆæ¨èåˆæ¬¡ä½¿ç”¨ï¼‰

åŒå‡» `E:\Project\MusicServer\start_navidrome.bat`

æµè§ˆå™¨è®¿é—®: **http://localhost:4533**

### æ–¹å¼äºŒï¼šå‘½ä»¤è¡Œå¯åŠ¨

```powershell
E:\Project\MusicServer\Navidrome\bin\navidrome.exe -c E:\Project\MusicServer\Navidrome\navidrome.toml
```

### æ–¹å¼ä¸‰ï¼šè®¾ä¸º Windows æœåŠ¡ï¼ˆå¼€æœºè‡ªå¯ï¼‰

```powershell
# éœ€è¦ç®¡ç†å‘˜æƒé™
# ä¸‹è½½ NSSM: https://nssm.cc/download
nssm install Navidrome "E:\Project\MusicServer\Navidrome\bin\navidrome.exe"
nssm set Navidrome AppDirectory "E:\Project\MusicServer\Navidrome"
nssm set Navidrome AppParameters "-c E:\Project\MusicServer\Navidrome\navidrome.toml"
nssm set Navidrome DisplayName "Navidrome Music Server"
nssm set Navidrome Start SERVICE_AUTO_START
nssm start Navidrome
```

---

## ç¬¬äº”é˜¶æ®µï¼šé¦–æ¬¡é…ç½® Navidrome

1. **åˆ›å»ºç®¡ç†å‘˜è´¦å·**
   - æµè§ˆå™¨è®¿é—® http://localhost:4533
   - é¦–æ¬¡è®¿é—®ä¼šè¦æ±‚åˆ›å»ºç®¡ç†å‘˜è´¦å·
   - å¡«å†™ç”¨æˆ·åå’Œå¯†ç ï¼ˆè¿™æ˜¯ä½ çš„éŸ³ä¹æœåŠ¡å™¨ç™»å½•ä¿¡æ¯ï¼Œå’Œ Bç«™æ— å…³ï¼‰

2. **è§¦å‘éŸ³ä¹åº“æ‰«æ**
   - ç™»å½•åç‚¹å‡»å³ä¸Šè§’å¤´åƒ â†’ è®¾ç½®
   - ç‚¹å‡» "Scan Library Now" / "ç«‹å³æ‰«æ"
   - ç­‰å¾…æ‰«æå®Œæˆï¼ˆä¸‹è½½çš„éŸ³ä¹æ–‡ä»¶è¶Šå¤šï¼Œæ‰«æè¶Šä¹…ï¼‰

3. **å¼€å§‹å¬æ­Œ**
   - å·¦ä¾§æ æµè§ˆä¸“è¾‘/è‰ºæœ¯å®¶/æ­Œæ›²
   - åˆ›å»ºæ’­æ”¾åˆ—è¡¨
   - æ’­æ”¾éŸ³ä¹

---

## ç¬¬å…­é˜¶æ®µï¼šå¤šç«¯è®¿é—®

### å±€åŸŸç½‘å†…è®¿é—®ï¼ˆæ‰‹æœº/å¹³æ¿ï¼‰

Navidrome ç»‘å®šåœ¨ `0.0.0.0:4533`ï¼Œå±€åŸŸç½‘è®¾å¤‡å¯ä»¥ç›´æ¥è®¿é—®ã€‚

1. æŸ¥çœ‹ç”µè„‘ IP:
   ```powershell
   ipconfig | Select-String "IPv4"
   ```
2. æ‰‹æœºæµè§ˆå™¨è®¿é—®: `http://ä½ çš„ç”µè„‘IP:4533`
   ä¾‹å¦‚: `http://192.168.1.100:4533`

### æ¨èå®¢æˆ·ç«¯ App

| å¹³å° | App | è¯´æ˜ |
|------|-----|------|
| **Android** | Subtracks | å¼€æºå…è´¹ï¼ŒMaterial Design |
| **Android** | DSub | ç»å…¸ Subsonic å®¢æˆ·ç«¯ |
| **Android** | Chora | å¼€æºï¼Œæ”¯æŒç¦»çº¿ä¸‹è½½ |
| **iOS** | Amperfy | å¼€æºå…è´¹ï¼Œæ”¯æŒ CarPlay |
| **iOS** | play:Sub | ä»˜è´¹ï¼ŒåŠŸèƒ½å®Œå–„ |
| **iOS** | Cassette | å¼€æºï¼ŒSwiftUI |
| **æ¡Œé¢** | Navidrome Web UI | æµè§ˆå™¨ç›´æ¥è®¿é—® |
| **æ¡Œé¢** | Aonsoku | Electron æ¡Œé¢å®¢æˆ·ç«¯ |

**æ‰‹æœº App é…ç½®æ–¹æ³•ï¼š**
- æœåŠ¡å™¨åœ°å€: `http://ä½ çš„ç”µè„‘IP:4533`
- ç”¨æˆ·å/å¯†ç : Navidrome ä¸­åˆ›å»ºçš„è´¦å·

### å¤–ç½‘è®¿é—®ï¼ˆå¯é€‰ï¼Œè¿›é˜¶ï¼‰

å¦‚éœ€åœ¨å¤–é¢ä¹Ÿèƒ½å¬æ­Œï¼Œéœ€è¦é…ç½®å†…ç½‘ç©¿é€ï¼š
- **Tailscale** (æ¨è): å…è´¹ï¼Œé›¶é…ç½® VPNï¼Œå®‰è£…åè‡ªåŠ¨åˆ†é…å›ºå®š IP
- **FRP**: éœ€è¦æœ‰å…¬ç½‘æœåŠ¡å™¨åšä¸­è½¬
- **Cloudflare Tunnel**: å…è´¹ï¼Œéœ€è¦åŸŸå

---

## å¸¸è§é—®é¢˜

### Q: ä¸‹è½½æŠ¥é”™ "Unable to extract JSON"
A: Cookie è¿‡æœŸäº†ï¼Œé‡æ–°å¯¼å‡º cookies.txt

### Q: ä¸‹è½½é€Ÿåº¦å¾ˆæ…¢
A: Bç«™æœ‰åçˆ¬é™åˆ¶ï¼Œå¯ä»¥åŠ  `--sleep-requests 1` å‚æ•°é™ä½è¯·æ±‚é¢‘ç‡

### Q: æ”¶è—å¤¹é‡Œæœ‰ééŸ³ä¹è§†é¢‘æ€ä¹ˆåŠ
A: è„šæœ¬å·²è®¾ç½® `--ignore-errors`ï¼Œä¼šè‡ªåŠ¨è·³è¿‡æ— æ³•å¤„ç†çš„è§†é¢‘

### Q: Navidrome æ‰«æä¸åˆ°æ–°æ–‡ä»¶
A: æ‰‹åŠ¨è§¦å‘æ‰«æï¼šè®¾ç½® â†’ Scan Library Nowï¼Œæˆ–é‡å¯ Navidrome

### Q: æ‰‹æœºè¿ä¸ä¸Š
A: æ£€æŸ¥ Windows é˜²ç«å¢™æ˜¯å¦æ”¾è¡Œäº† 4533 ç«¯å£ï¼š
```powershell
# æ·»åŠ é˜²ç«å¢™è§„åˆ™ (ç®¡ç†å‘˜æƒé™)
New-NetFirewallRule -DisplayName "Navidrome" -Direction Inbound -LocalPort 4533 -Protocol TCP -Action Allow
```

### Q: ä¸‹è½½çš„æ–‡ä»¶æ²¡æœ‰æ ‡é¢˜/è‰ºæœ¯å®¶ä¿¡æ¯
A: Bç«™è§†é¢‘æ²¡æœ‰æ ‡å‡†çš„éŸ³ä¹ ID3 æ ‡ç­¾ã€‚yt-dlp ä¼šç”¨è§†é¢‘æ ‡é¢˜ä½œä¸ºæ–‡ä»¶åï¼Œ
   Navidrome ä¼šè‡ªåŠ¨ç”¨æ–‡ä»¶ååŒ¹é…ã€‚å¯ä»¥åœ¨ Navidrome Web UI ä¸­æ‰‹åŠ¨ç¼–è¾‘æ ‡ç­¾ã€‚


---

## ¸è´Ê¹¦ÄÜ£¨ÒÑÅäÖÃÍê³É£©

ÒôÀÖ¿âÊ¹ÓÃ**Íâ²¿ LRC ¸è´ÊÎÄ¼ş**£ºÃ¿Ê× `xxx.mp3` ÅÔ±ß·ÅÒ»¸öÍ¬ÃûµÄ `xxx.lrc`£¬
Navidrome »áÔÚ²¥·ÅÊ±×Ô¶¯¶ÁÈ¡²¢ÏÔÊ¾¹ö¶¯¸è´Ê¡£

> ×¢Òâ£ºÍâ²¿¸è´ÊÊÇ**²¥·ÅÇëÇóÊ±ÊµÊ±¶ÁÈ¡**µÄ£¬²»Ğ´½øÊı¾İ¿â¡£
> ËùÒÔ¼ÓÁË .lrc Ö®ºó**²»ĞèÒªÖØĞÂÉ¨Ãè**£¬Ë¢ĞÂÒ³Ãæ¼´¿É¿´µ½¡£

### ¸øĞÂÏÂÔØµÄ¸è×Ô¶¯×¥¸è´Ê

```powershell
# Ö»¸ø»¹Ã»ÓĞ .lrc µÄ¸è×¥È¡£¨ÔöÁ¿£¬ÍÆ¼öÈÕ³£ÓÃ£©
E:\Project\MusicServer\fetch_lyrics.ps1

# ÏÈÔ¤ÀÀÆ¥Åä½á¹û£¬²»Ğ´ÎÄ¼ş
E:\Project\MusicServer\fetch_lyrics.ps1 -DryRun

# Ö»´¦ÀíÄ³¼¸Ê×
E:\Project\MusicServer\fetch_lyrics.ps1 -Filter "*ĞíáÔ*"

# Ç¿ÖÆ¸²¸ÇÒÑÓĞµÄ .lrc
E:\Project\MusicServer\fetch_lyrics.ps1 -Force
```

¸è´ÊÀ´Ô´ÎªÍøÒ×ÔÆÒôÀÖ£¬½Å±¾»á´ÓÎÄ¼şÃû½âÎöÇúÃû/¸èÊÖ£¬
ÔÙÓÃ"Ê±³¤ + Ãû³ÆÏàËÆ¶È"´ò·ÖÌô×îÆ¥ÅäµÄ°æ±¾£¬ÈÕÎÄ¸è»á×Ô¶¯¸½ÉÏÖĞÎÄ·­Òë¡£
Ã¿´ÎÔËĞĞ¶¼»áÉú³É±¨¸æ `E:\Project\MusicServer\lyrics_report.csv`£¬
ÆäÖĞ `Status` ÁĞº¬Òå£º

| Status | º¬Òå |
|--------|------|
| OK | ¸ßÖÃĞÅÆ¥Åä |
| SUSPECT | Ê±³¤²î½Ï´ó£¬½¨ÒéÈË¹¤ºË¶Ô |
| NO_LYRIC | Æ¥Åäµ½ÁËµ«¸ÃÇúÎŞ¸è´Ê£¨´¿ÒôÀÖ/·­³ª£© |
| NO_MATCH | ÍøÒ×ÔÆËÑ²»µ½ |

### Ä³Ê×¸è´ÊÆ¥Åä´íÁË£¬ÊÖ¶¯ĞŞ

```powershell
# µÚÒ»²½£ºËÑË÷ºòÑ¡£¬¿´ÄÄ¸ö ID ²Å¶Ô
E:\Project\MusicServer\fix_one_lyric.ps1 -FilePattern "*¸èÃû¹Ø¼ü´Ê*" -Search "ÕıÈ·µÄÇúÃû ¸èÊÖ"

# µÚ¶ş²½£ºÓÃ²éµ½µÄ ID ¸²¸ÇĞ´Èë
E:\Project\MusicServer\fix_one_lyric.ps1 -FilePattern "*¸èÃû¹Ø¼ü´Ê*" -SongId 1234567890
```

### µ±Ç°¸²¸ÇÇé¿ö

159 Ê×ÖĞ 151 Ê×ÓĞ¸è´Ê£¨95%£©¡£Ê£Óà 8 Ê×ÊÇ´¿Æ÷ÀÖ£¨Èç Steve Vai£©¡¢
10 ÃëÆ¬¶Î¡¢»òÍøÒ×ÔÆÃ»ÓĞ¶ÔÓ¦°æ±¾µÄ·­³ª/Live ÏÖ³¡£¬ÊôÕı³£È±Ê§¡£
²»ÏëÒªÄ³Ê×µÄ¸è´ÊÊ±£¬Ö±½ÓÉ¾µô¶ÔÓ¦µÄ `.lrc` ÎÄ¼ş¼´¿É¡£

---

## Ã¿ÈÕÍÆ¼ö£¨ÈÕÍÆ£©

Ã¿ÌìÔçÉÏ×Ô¶¯ÍÆ¼ö 30 Ê×ĞÂ¸è£¬ÄãÌıÍêµã?±£Áô£¬Ã»µã?µÄ´ÎÈÕ×Ô¶¯É¾³ıÇÒÓÀ²»ÔÙÍÆ¡£

### ¹¤×÷Ô­Àí

```
ÄãµÄÒôÀÖ¿â(162Ê×)  ©¤©¤©´
Navidrome ĞÇ±êµÄ¸è ©¤©¤©à©¤¡ú ³é 12 Ê×ÖÖ×Ó ©¤¡ú ÍøÒ×ÔÆ"ÏàËÆ¸èÇú"API
ÒÑ?¹ıµÄÈÕÍÆ       ©¤©¤©¼                          ©¦
                                               ¡ı
                                     ºòÑ¡ 50~80 Ê×
                                               ©¦
              ¹ıÂË£ºÒÑÓĞµÄ / ºÚÃûµ¥ / ºÏ¼¯°é×àDJ°æ / Ê±³¤Òì³£
                                               ¡ı
                                        È¡ 30 Ê×
                                               ¡ı
                              BÕ¾ËÑË÷ÏÂÔØ ©¤¡ú Ê±³¤Ğ£Ñé ©¤¡ú ×¥¸è´Ê
                                               ¡ı
                              Music\DailyMix\  (Navidrome ×Ô¶¯Èë¿â)
```

ÍÆ¼ö»á**ÏŞÖÆÍ¬Ò»ÒÕÊõ¼Ò×î¶à 3 Ê×**£¬±ÜÃâÕûÌì¶¼ÊÇÍ¬Ò»¸öÀÖ¶Ó¡£

### Ã¿ÌìÄãÒª×öµÄÊÂ

**Ö»ÓĞÒ»¼ş£ºÔÚ Navidrome ÀïÌı£¬Ï²»¶µÄµã?£¨Heart / ÊÕ²Ø£©¡£**

Ê£ÏÂÈ«×Ô¶¯£º

| Ê±¼ä | ÈÎÎñ | ĞĞÎª |
|------|------|------|
| 06:30 | `MusicServer_DailyCleanup` | ×òÌìµã?µÄÒÆÈëÖ÷¿â£¬Ã»µã?µÄÉ¾³ı²¢À­ºÚ |
| 07:00 | `MusicServer_DailyRecommend` | ÍÆ¼ö²¢ÏÂÔØ½ñÌìµÄ 30 Ê× |

µ±ÌìÏÂÔØµÄ¸è**²»»áµ±Ìì±»É¾**£¬ÄãÓĞÍêÕûÒ»ÌìÊ±¼äÌı¡£

### ÊÖ¶¯²Ù×÷

```powershell
# Á¢¿ÌÀ´Ò»ÅúÍÆ¼ö£¨ÏÈ¿´¿´ÍÆÊ²Ã´£¬²»ÏÂÔØ£©
E:\Project\MusicServer\daily_recommend.ps1 -DryRun

# Á¢¿ÌÏÂÔØ 30 Ê×
E:\Project\MusicServer\daily_recommend.ps1

# Ö»Òª 10 Ê×
E:\Project\MusicServer\daily_recommend.ps1 -Count 10

# ÊÖ¶¯ÇåÀí£¨ÏÈÔ¤ÀÀ»áÉ¾Ê²Ã´£©
E:\Project\MusicServer\daily_cleanup.ps1 -DryRun
E:\Project\MusicServer\daily_cleanup.ps1
```

### Êı¾İÎÄ¼ş

¶¼ÔÚ `E:\Project\MusicServer\DailyMix_data\`£º

| ÎÄ¼ş | ×÷ÓÃ |
|------|------|
| `today.csv` | ½ñÈÕÍÆ¼öÇåµ¥£¨ÇåÀí½Å±¾µÄÒÀ¾İ£© |
| `history.csv` | ËùÓĞÍÆ¼ö¹ıµÄ¸è |
| `accepted.csv` | Äã?¹ıµÄ¸è ¡ª¡ª **»á×÷Îª¸ßÈ¨ÖØÖÖ×ÓÓ°ÏìºóĞøÍÆ¼ö** |
| `rejected.csv` | ÄãÃ»?µÄ¸è ¡ª¡ª **ÓÀ²»ÔÙÍÆ** |

ËùÒÔÓÃµÃÔ½¾ÃÔ½×¼£ºÏ²»¶µÄ»á´øÀ´¸ü¶àÍ¬Àà£¬¾Ü¾øµÄ²»»áÔÙ³öÏÖ¡£

### ³£¼ûÎÊÌâ

**Q: ÍÆ¼öÀïÓĞĞ©¸èÃ÷ÏÔ²»ÊÇÎÒÒªµÄ**
A: ²»µã?¾ÍĞĞ£¬´ÎÈÕ×Ô¶¯É¾³ıÇÒ½øºÚÃûµ¥¡£ÏëÁ¢¿ÌÌŞ³ı¿ÉÖ±½ÓÉ¾ `Music\DailyMix\` ÀïµÄÎÄ¼ş£¬
   µ«ÄÇÑù²»»á½øºÚÃûµ¥£¨ÒÔºó¿ÉÄÜÔÙÍÆ£©£¬½¨Òé½»¸øÇåÀí½Å±¾´¦Àí¡£

**Q: ÏÂÔØÊ§°Ü/ÊıÁ¿²»×ã 30 Ê×**
A: BÕ¾ÓĞ·´ÅÀÏŞÁ÷£¨HTTP 412£©£¬½Å±¾ÒÑÄÚÖÃ 3 ´ÎÖØÊÔ¡£ÀäÃÅ¸è B Õ¾¿ÉÄÜÈ·ÊµÃ»ÓĞ£¬
   ÊôÕı³£ËğºÄ£¬Ò»°ãÄÜÄÃµ½ 20~28 Ê×¡£

**Q: Ê±³¤²»·û±»¶ªÆúÊÇÊ²Ã´ÒâË¼**
A: BÕ¾ËÑË÷¿ÉÄÜÃüÖĞ´íÎóÊÓÆµ£¨Èç·­³ª¡¢´®ÉÕ£©¡£½Å±¾»á±È¶Ô±¾µØÊ±³¤ÓëÍøÒ×ÔÆÊ±³¤£¬
   ²îÒì³¬¹ı 45 Ãë¾Í¶ªÆú£¬ÕâÊÇ·ÀÖ¹ÍÆ¼öÀï»ìÈë´íÎóÒôÆµµÄ±£»¤»úÖÆ¡£

**Q: ÏëÔİÍ£ÈÕÍÆ**
A: `Disable-ScheduledTask -TaskName "MusicServer_DailyRecommend"`£¬
   »Ö¸´ÓÃ `Enable-ScheduledTask`¡£

**Q: cookies ¹ıÆÚÁË**
A: ±íÏÖÎªÏÂÔØÈ«²¿Ê§°Ü¡£ÖØĞÂÓÃä¯ÀÀÆ÷²å¼şµ¼³ö `cookies.txt` ¸²¸Çµ½
   `E:\Project\MusicServer\cookies.txt` ¼´¿É¡£