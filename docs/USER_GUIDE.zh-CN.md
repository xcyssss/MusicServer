# B站收藏夹 → Navidrome 音乐服务器 完整教程

## 目录结构

```
E:\Project\MusicServer\
├── Music\                          ← 音乐文件存放处
├── Navidrome\
│   ├── bin\navidrome.exe           ← Navidrome 程序
│   ├── navidrome.toml              ← 配置文件
│   ├── navidrome.log               ← 日志文件
│   └── Data\                       ← 数据库和缓存
├── scripts/maintenance/             ← 维护工具
│   ├── download_bilibili_favorites.ps1 ← B站下载脚本
│   ├── fetch_lyrics.ps1            ← 歌词抓取
│   ├── fix_one_lyric.ps1           ← 单曲歌词修复
│   ├── fix_tags.ps1                ← 标签修复
│   └── add_song.ps1                ← 单曲下载
└── start_musicserver_ui.bat        ← 启动脚本
```

---

## 第一阶段：环境准备（已完成 ✅）

| 组件 | 状态 | 位置 |
|------|------|------|
| yt-dlp | ✅ 已安装 v2026.07.04 | C:\Users\dell\anaconda3\Scripts\yt-dlp.exe |
| ffmpeg | ✅ 已安装 | C:\Users\dell\AppData\Local\Microsoft\WinGet\Links\ffmpeg.exe |
| Navidrome | ✅ 已下载 v0.63.2 | E:\Project\MusicServer\Navidrome\bin\navidrome.exe |
| 配置文件 | ✅ 已创建 | E:\Project\MusicServer\Navidrome\navidrome.toml |
| 下载脚本 | ✅ 已创建 | E:\Project\MusicServer\scripts\maintenance\download_bilibili_favorites.ps1 |
| 启动脚本 | ✅ 已创建 | E:\Project\MusicServer\start_navidrome.bat |

---

## 第二阶段：获取 B站 Cookie（你需要手动操作）

yt-dlp 下载收藏夹需要你的 B站登录 Cookie，用于验证身份。

### 步骤：

1. **安装 Cookie 导出插件**
   - Chrome/Edge: 安装 [Get cookies.txt LOCALLY](https://chromewebstore.google.com/detail/get-cookiestxt-locally/cclelndahbckbenkjhflpdbgdldlbecc)
   - Firefox: 安装 [cookies.txt](https://addons.mozilla.org/firefox/addon/cookies-txt/)

2. **在浏览器中登录 B站** (https://www.bilibili.com)
   - 确保你已经登录并且能看到你的收藏夹

3. **导出 Cookie**
   - 点击浏览器右上角的插件图标
   - 选择 "Export" / "导出"
   - 保存为 `cookies.txt`，放到 `E:\Project\MusicServer\cookies.txt`

4. **获取收藏夹 URL**
   - 打开你的收藏夹页面
   - URL 类似: `https://www.bilibili.com/medialist/detail/ml1234567890`
   - 其中 `ml1234567890` 就是你收藏夹的编号

---

## 第三阶段：下载收藏夹音频

### 基本命令（使用脚本）

```powershell
# 在 PowerShell 中运行
cd E:\Project\MusicServer

# 下载收藏夹（需要替换为你的收藏夹 URL）
.\scripts\maintenance\download_bilibili_favorites.ps1 `
    -FavoritesUrl "https://www.bilibili.com/medialist/detail/ml你的收藏夹编号" `
    -CookieFile "E:\Project\MusicServer\cookies.txt"
```

### 常用操作

```powershell
# 查看下载了多少文件
Get-ChildItem "E:\Project\MusicServer\Music" -Filter *.mp3 | Measure-Object | Select-Object Count

# 查看下载的文件
Get-ChildItem "E:\Project\MusicServer\Music" | Select-Object Name, @{N='Size(MB)';E={[math]::Round($_.Length/1MB,1)}}

# 只下载前 10 个视频（测试用）
# 在脚本命令后加 --playlist-end 10
```

### 只下载单个视频的音频

```powershell
yt-dlp --extract-audio --audio-format mp3 --audio-quality 0 `
    --embed-thumbnail --embed-metadata `
    --cookies "E:\Project\MusicServer\cookies.txt" `
    -o "E:\Project\MusicServer\Music\%(title)s.%(ext)s" `
    "https://www.bilibili.com/video/BVxxxxxxxx"
```

### 只下载收藏夹中新增的歌曲

yt-dlp 会自动跳过已下载的文件（`--no-overwrites`），
直接重新运行下载脚本即可只下载新增内容。

---

## 第四阶段：启动 Navidrome 服务器

### 方式一：手动启动（推荐初次使用）

双击 `E:\Project\MusicServer\start_navidrome.bat`

浏览器访问: **http://localhost:4533**

### 方式二：命令行启动

```powershell
E:\Project\MusicServer\Navidrome\bin\navidrome.exe -c E:\Project\MusicServer\Navidrome\navidrome.toml
```

### 方式三：设为 Windows 服务（开机自启）

```powershell
# 需要管理员权限
# 下载 NSSM: https://nssm.cc/download
nssm install Navidrome "E:\Project\MusicServer\Navidrome\bin\navidrome.exe"
nssm set Navidrome AppDirectory "E:\Project\MusicServer\Navidrome"
nssm set Navidrome AppParameters "-c E:\Project\MusicServer\Navidrome\navidrome.toml"
nssm set Navidrome DisplayName "Navidrome Music Server"
nssm set Navidrome Start SERVICE_AUTO_START
nssm start Navidrome
```

---

## 第五阶段：首次配置 Navidrome

1. **创建管理员账号**
   - 浏览器访问 http://localhost:4533
   - 首次访问会要求创建管理员账号
   - 填写用户名和密码（这是你的音乐服务器登录信息，和 B站无关）

2. **触发音乐库扫描**
   - 登录后点击右上角头像 → 设置
   - 点击 "Scan Library Now" / "立即扫描"
   - 等待扫描完成（下载的音乐文件越多，扫描越久）

3. **开始听歌**
   - 左侧栏浏览专辑/艺术家/歌曲
   - 创建播放列表
   - 播放音乐

---

## 第六阶段：多端访问

### 局域网内访问（手机/平板）

Navidrome 绑定在 `0.0.0.0:4533`，局域网设备可以直接访问。

1. 查看电脑 IP:
   ```powershell
   ipconfig | Select-String "IPv4"
   ```
2. 手机浏览器访问: `http://你的电脑IP:4533`
   例如: `http://192.168.1.100:4533`

### 推荐客户端 App

| 平台 | App | 说明 |
|------|-----|------|
| **Android** | Subtracks | 开源免费，Material Design |
| **Android** | DSub | 经典 Subsonic 客户端 |
| **Android** | Chora | 开源，支持离线下载 |
| **iOS** | Amperfy | 开源免费，支持 CarPlay |
| **iOS** | play:Sub | 付费，功能完善 |
| **iOS** | Cassette | 开源，SwiftUI |
| **桌面** | Navidrome Web UI | 浏览器直接访问 |
| **桌面** | Aonsoku | Electron 桌面客户端 |

**手机 App 配置方法：**
- 服务器地址: `http://你的电脑IP:4533`
- 用户名/密码: Navidrome 中创建的账号

### 外网访问（可选，进阶）

如需在外面也能听歌，需要配置内网穿透：
- **Tailscale** (推荐): 免费，零配置 VPN，安装后自动分配固定 IP
- **FRP**: 需要有公网服务器做中转
- **Cloudflare Tunnel**: 免费，需要域名

---

## 常见问题

### Q: 下载报错 "Unable to extract JSON"
A: Cookie 过期了，重新导出 cookies.txt

### Q: 下载速度很慢
A: B站有反爬限制，可以加 `--sleep-requests 1` 参数降低请求频率

### Q: 收藏夹里有非音乐视频怎么办
A: 脚本已设置 `--ignore-errors`，会自动跳过无法处理的视频

### Q: Navidrome 扫描不到新文件
A: 手动触发扫描：设置 → Scan Library Now，或重启 Navidrome

### Q: 手机连不上
A: 检查 Windows 防火墙是否放行了 4533 端口：
```powershell
# 添加防火墙规则 (管理员权限)
New-NetFirewallRule -DisplayName "Navidrome" -Direction Inbound -LocalPort 4533 -Protocol TCP -Action Allow
```

### Q: 下载的文件没有标题/艺术家信息
A: B站视频没有标准的音乐 ID3 标签。yt-dlp 会用视频标题作为文件名，
   Navidrome 会自动用文件名匹配。可以在 Navidrome Web UI 中手动编辑标签。


---

## ��ʹ��ܣ���������ɣ�

���ֿ�ʹ��**�ⲿ LRC ����ļ�**��ÿ�� `xxx.mp3` �Ա߷�һ��ͬ���� `xxx.lrc`��
Navidrome ���ڲ���ʱ�Զ���ȡ����ʾ������ʡ�

> ע�⣺�ⲿ�����**��������ʱʵʱ��ȡ**�ģ���д�����ݿ⡣
> ���Լ��� .lrc ֮��**����Ҫ����ɨ��**��ˢ��ҳ�漴�ɿ�����

### �������صĸ��Զ�ץ���

```powershell
# ֻ����û�� .lrc �ĸ�ץȡ���������Ƽ��ճ��ã�
E:\Project\MusicServer\scripts\maintenance\fetch_lyrics.ps1

# ��Ԥ��ƥ��������д�ļ�
E:\Project\MusicServer\scripts\maintenance\fetch_lyrics.ps1 -DryRun

# ֻ����ĳ����
E:\Project\MusicServer\scripts\maintenance\fetch_lyrics.ps1 -Filter "*����*"

# ǿ�Ƹ������е� .lrc
E:\Project\MusicServer\scripts\maintenance\fetch_lyrics.ps1 -Force
```

�����ԴΪ���������֣��ű�����ļ�����������/���֣�
����"ʱ�� + �������ƶ�"�������ƥ��İ汾�����ĸ���Զ��������ķ��롣
ÿ�����ж������ɱ��� `E:\Project\MusicServer\lyrics_report.csv`��
���� `Status` �к��壺

| Status | ���� |
|--------|------|
| OK | ������ƥ�� |
| SUSPECT | ʱ����ϴ󣬽����˹��˶� |
| NO_LYRIC | ƥ�䵽�˵������޸�ʣ�������/������ |
| NO_MATCH | �������Ѳ��� |

### ĳ�׸��ƥ����ˣ��ֶ���

```powershell
# ��һ����������ѡ�����ĸ� ID �Ŷ�
E:\Project\MusicServer\scripts\maintenance\fix_one_lyric.ps1 -FilePattern "*�����ؼ���*" -Search "��ȷ������ ����"

# �ڶ������ò鵽�� ID ����д��
E:\Project\MusicServer\scripts\maintenance\fix_one_lyric.ps1 -FilePattern "*�����ؼ���*" -SongId 1234567890
```

### ��ǰ�������

159 ���� 151 ���и�ʣ�95%����ʣ�� 8 ���Ǵ����֣��� Steve Vai����
10 ��Ƭ�Ρ���������û�ж�Ӧ�汾�ķ���/Live �ֳ���������ȱʧ��
����Ҫĳ�׵ĸ��ʱ��ֱ��ɾ����Ӧ�� `.lrc` �ļ����ɡ�

---

## ÿ���Ƽ������ƣ�

ÿ�������Զ��Ƽ� 30 ���¸裬�������?������û��?�Ĵ����Զ�ɾ�����������ơ�

### ����ԭ��

```
������ֿ�(162��)  ������
Navidrome �Ǳ�ĸ� �����੤�� �� 12 ������ ���� ������"���Ƹ���"API
��?��������       ������                          ��
                                               ��
                                     ��ѡ 50~80 ��
                                               ��
              ���ˣ����е� / ������ / �ϼ�����DJ�� / ʱ���쳣
                                               ��
                                        ȡ 30 ��
                                               ��
                              Bվ�������� ���� ʱ��У�� ���� ץ���
                                               ��
                              Music\DailyMix\  (Navidrome �Զ����)
```

�Ƽ���**����ͬһ��������� 3 ��**���������춼��ͬһ���ֶӡ�

### ÿ����Ҫ������

**ֻ��һ������ Navidrome ������ϲ���ĵ�?��Heart / �ղأ���**

ʣ��ȫ�Զ���

| ʱ�� | ���� | ��Ϊ |
|------|------|------|
| 06:30 | `MusicServer_DailyCleanup` | �����?���������⣬û��?��ɾ�������� |
| 07:00 | `MusicServer_DailyRecommend` | �Ƽ������ؽ���� 30 �� |

�������صĸ�**���ᵱ�챻ɾ**����������һ��ʱ������

### �ֶ�����

```powershell
# ������һ���Ƽ����ȿ�����ʲô�������أ�
E:\Project\MusicServer\daily_recommend.ps1 -DryRun

# �������� 30 ��
E:\Project\MusicServer\daily_recommend.ps1

# ֻҪ 10 ��
E:\Project\MusicServer\daily_recommend.ps1 -Count 10

# �ֶ���������Ԥ����ɾʲô��
E:\Project\MusicServer\daily_cleanup.ps1 -DryRun
E:\Project\MusicServer\daily_cleanup.ps1
```

### �����ļ�

���� `E:\Project\MusicServer\DailyMix_data\`��

| �ļ� | ���� |
|------|------|
| `today.csv` | �����Ƽ��嵥�������ű������ݣ� |
| `history.csv` | �����Ƽ����ĸ� |
| `accepted.csv` | ��?���ĸ� ���� **����Ϊ��Ȩ������Ӱ������Ƽ�** |
| `rejected.csv` | ��û?�ĸ� ���� **��������** |

�����õ�Խ��Խ׼��ϲ���Ļ��������ͬ�࣬�ܾ��Ĳ����ٳ��֡�

### ��������

**Q: �Ƽ�����Щ�����Բ�����Ҫ��**
A: ����?���У������Զ�ɾ���ҽ����������������޳���ֱ��ɾ `Music\DailyMix\` ����ļ���
   ��������������������Ժ�������ƣ������齻�������ű�������

**Q: ����ʧ��/�������� 30 ��**
A: Bվ�з���������HTTP 412�����ű������� 3 �����ԡ����Ÿ� B վ����ȷʵû�У�
   ��������ģ�һ�����õ� 20~28 �ס�

**Q: ʱ��������������ʲô��˼**
A: Bվ�����������д�����Ƶ���緭�������գ����ű���ȶԱ���ʱ����������ʱ����
   ���쳬�� 45 ��Ͷ��������Ƿ�ֹ�Ƽ�����������Ƶ�ı������ơ�

**Q: ����ͣ����**
A: `Disable-ScheduledTask -TaskName "MusicServer_DailyRecommend"`��
   �ָ��� `Enable-ScheduledTask`��

**Q: cookies ������**
A: ����Ϊ����ȫ��ʧ�ܡ������������������� `cookies.txt` ���ǵ�
   `E:\Project\MusicServer\cookies.txt` ���ɡ�