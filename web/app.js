// Tauri startup uses this marker to reject a stale 8790 UI process after an
// upgrade. Keep it in the served bundle so the desktop shell can verify that
// the WebView is loading the same source revision as the backend.
const MUSICSERVER_BUILD_MARKER = 'musicserver-development';

const storedLibraryOrder = (() => {
  try {
    const value = JSON.parse(localStorage.getItem('musicserver-library-order') || '[]');
    return Array.isArray(value) ? value.map(String) : [];
  } catch { return []; }
})();

const state = {
  items: [],
  wanted: [],
  library: [],
  librarySequence: [],
  listening: { mostPlayed: [], rediscover: [], loaded: false },
  libraryOrder: storedLibraryOrder,
  currentKey: null,
  currentItem: null,
  currentCollection: 'library',
  playbackSession: null,
  lastRandomId: null,
  mode: localStorage.getItem('musicserver-play-mode') === 'random' && storedLibraryOrder.length ? 'random' : 'sequence',
  librarySort: localStorage.getItem('musicserver-library-sort') || 'default',
  // Which names the library shows. The server stores the choice; 'raw'
  // (traditional) is the product default, so an unreachable API keeps the
  // original folder names instead of silently regularizing them.
  displayMode: 'raw',
  lyrics: { available: false, format: '', text: '', entries: [], quality: '', message: '' },
  lyricsRequest: 0,
  playRequest: 0,
  libraryRevision: 0,
  recommendationRevision: 0,
  libraryLimit: 200,
  searchQuery: '',
};

const labels = { REMOTE: '在线', WANTED: '待下载', RESOLVING: '正在解析', DOWNLOADING: '下载中', VALIDATING: '校验中', CANCEL_REQUESTED: '正在取消', LOCAL: '已本地化', RETRY_WAIT: '等待重试', UNAVAILABLE: '暂不可用' };
const $ = (selector) => document.querySelector(selector);
const escapeHtml = (value) => String(value ?? '').replace(/[&<>'"]/g, (char) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;' }[char]));
const duration = (seconds) => { const value = Number(seconds || 0); return value ? `${Math.floor(value / 60)}:${String(Math.floor(value % 60)).padStart(2, '0')}` : '—'; };
const localIdFromItem = (item) => {
  if (!item) return '';
  const direct = String(item.library_id || item.id || '');
  if (/^(library-|na-)/.test(direct)) return direct;
  const playbackId = String(item.playback_source?.id || '');
  if (/^(library-|na-)/.test(playbackId)) return playbackId;
  const stream = String(item.stream_url || item.playback_source?.url || '');
  const match = /\/api\/library\/([^/]+)\/stream(?:$|\?)/.exec(stream);
  return match ? decodeURIComponent(match[1]) : '';
};
const keyOf = (item) => localIdFromItem(item) || String(item?.track_id || item?.id || '');
const itemStatus = (item) => item.wanted?.state || item.local_status || 'REMOTE';
const statusClass = (status) => status === 'LOCAL' ? 'local' : ['DOWNLOADING', 'RESOLVING', 'VALIDATING'].includes(status) ? 'downloading' : ['RETRY_WAIT', 'CANCEL_REQUESTED'].includes(status) ? 'retry' : '';
const normalizeLibraryItem = (item) => ({ ...item, title: item?.title || item?.name || '' });

// --- Song name cleaning / formatting ---
// Library filenames are frequently raw 视频 title dumps such as
//   【附歌词中字】Roselia-「THRONE OF ROSE」FULL
//   在百万豪装录音棚大声听 王菲《百年孤寂》【Hi-res】
// The goal is a readable song title, never a labelled-but-wrong one: when no
// candidate looks like a song name the original title is kept verbatim, so two
// different files can never collapse onto the same placeholder row.
const NOISE_WORDS = [
  '官方MV', 'OfficialMusicVideo', 'Official Music Video', 'MV', 'PROMO',
  '百万级装备试听', '百万级高品质试听', '百万级装备', '百级装备试听',
  '在百万豪装录音棚大声听', '百万豪装录音棚大声听', '百万豪装录音棚', '百万豪装', '录音棚', '大声听',
  'Hi-Res无损音质', 'Hi-Res无损臻享', 'Hi-Res无损', 'Hi-res无损', 'Hi-Res', 'Hi-res',
  '无损音质', '无损臻享', '无损', '臻享', '臻品', '高音质', '高品质',
  '4K60fps', '4K60P', '4K60', '4K', '黑胶', 'BD中字', '中文字幕', '中日字幕', '中英字幕', '中字',
  '动态歌词排版', '动态水印', '动态歌词', '单曲纯享', '纯享版', '静享版', '试听',
  '附歌词中字', '附中日歌词', '附歌词', '附中文字幕', '附字幕', 'FULL', '完整版',
  '完美药药', '完美', '直播', '翻唱', 'Cover', 'cover',
  '现代战争', '游戏原声', '动漫原声', '动漫', 'OST', 'ost', '原声',
];
const SONG_DESC_WORDS = [
  '德国钢琴家', '百万豪装录音棚', '百万级装备', '金榜提名', '金榜题名', '九周年纪念',
  '周年纪念', '动态水印', '动态歌词排版', '先约电台', '温柔女声版', '太美啦',
  '火速翻唱', '静享版', '纯享版', '完整版', '无损音质', '无损臻享', '高音质', '高品质',
];
const SONG_DESC_RE = /(知道|好听|好听|流泪|拉满|喜欢|推荐|纪念|祝贺|祝大家|金榜|太好听|震撼|绝了|开口跪|附歌词|动态|完整版|remix|翻唱|cover|mv|live|版本|臻享|臻品)/i;
const EPISODE_RE = /(?:^|[\s|｜\-–—_/／])(?:p|part|ep|vol|track)\s*\.?\s*0*\d{1,3}\b/gi;
const LIVE_RE = /(^|[^a-z0-9])(live)(?![a-z0-9])/i;
const COVER_RE = /(^|[^a-z0-9])(cover|翻唱)(?![a-z0-9])/i;
// A bare marker word left at the end of a title after its singer credit is cut,
// with or without brackets: `… for the love of god（上帝的爱）live`.
const TAIL_MARKER_RE = /[\s\-\u2013\u2014|｜]*[\uFF08(\u3010[]?\s*(?:live|cover|翻唱)\s*[\uFF09)\u3011\]]?\s*$/i;
const HAN_OR_ALNUM_RE = /[\u3400-\u9fff\uf900-\ufaff\u3040-\u30ffa-z0-9]/i;
const SONG_BRACKET_RE = /[\u300A\u300B\u300C\u300D\u300E\u300F]/;

function escapeRe(value) { return String(value).replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }
const NOISE_RES = NOISE_WORDS.map((word) => new RegExp(escapeRe(word), 'gi'));
const DESC_RES = SONG_DESC_WORDS.map((word) => new RegExp(escapeRe(word) + '[^\\s，。！？、|｜]*', 'g'));
const BRACKET_RES = [
  [/【[^【】]{0,80}】/g, ' '],
  [/\[[^\[\]]{0,80}\]/g, ' '],
  [/（[^（）]{1,40}）/g, ' '],
  [/\([^()]{1,40}\)/g, ' '],
  [/《[^《》]{0,60}》/g, ' '],
  [/「[^「」]{0,60}」/g, ' '],
  [/『[^『』]{0,60}』/g, ' '],
  [/[「」『』《》【】\[\]（）()“”‘’]/g, ' '],
];
const BRACKET_PAIRS = [
  { open: '\u300C', close: '\u300D', min: 2, max: 60 }, // 「」
  { open: '\u300E', close: '\u300F', min: 2, max: 60 }, // 『』
  { open: '\u300A', close: '\u300B', min: 2, max: 80 }, // 《》
];

function bracketCandidates(raw) {
  const found = [];
  for (const pair of BRACKET_PAIRS) {
    let from = 0;
    for (;;) {
      const start = raw.indexOf(pair.open, from);
      if (start < 0) break;
      const end = raw.indexOf(pair.close, start + 1);
      if (end < 0) break;
      const content = raw.slice(start + 1, end);
      if (content.length >= pair.min && content.length <= pair.max) found.push({ content, start, end });
      from = end + 1;
    }
  }
  return found.sort((a, b) => a.start - b.start);
}

function stripBrackets(text) {
  let value = String(text);
  for (const [re, replacement] of BRACKET_RES) value = value.replace(re, replacement);
  return value;
}

function stripNoise(text) {
  let value = String(text);
  for (const re of NOISE_RES) value = value.replace(re, ' ');
  for (const re of DESC_RES) value = value.replace(re, ' ');
  value = value.replace(EPISODE_RE, ' ');
  value = value.replace(/\s*[|｜]\s*/g, ' | ');
  value = value.replace(/^[\s\-–—_/／·、,，。!！?？:：+~～*"'“”‘’]+/, '').replace(/[\s\-–—_/／·、,，!！?？:：+~～*"'“”‘’]+$/, '');
  return value.replace(/\s+/g, ' ').trim();
}

function isSongLike(text) {
  const value = String(text || '').trim();
  if (value.length < 2 || value.length > 60) return false;
  return HAN_OR_ALNUM_RE.test(value);
}

function cutDescriptiveTail(text) {
  const value = String(text);
  const parts = value.split(/[,，]|(?:\s+[—–-]{1,2}\s+)/).map((part) => part.trim()).filter(Boolean);
  if (parts.length < 2) return value;
  const head = parts[0];
  if (head.length >= 2 && head.length <= 20 && !/(知道|好听|流泪|喜欢|纪念|金榜|祝)/.test(head)) return head;
  return value;
}

// `流浪的猫写情诗·甜到掉牙的静享版`: a `·` tail is a subtitle about the upload
// ("甜到掉牙的"), not part of the song. `青玉案·元夕` is a real title, so only a
// tail that quite clearly reads as a descriptor is cut.
const DESCRIPTIVE_TAIL_RE = /(的|版|篇|系列|字幕|音质|现场|翻唱|伴奏|纯音乐|完整版)$/;

function dotTruncatedHead(text) {
  const value = String(text || '').trim();
  const parts = value.split(/[·・]/);
  if (parts.length < 2) return '';
  const head = parts[0].trim();
  const tail = parts.slice(1).join('·').trim();
  if (head.length < 2 || !tail || !isSongLike(head)) return '';
  return DESCRIPTIVE_TAIL_RE.test(tail) ? head : '';
}

// `…｜Divide⧸Unite p02 Ringing Bloom` — inside a multi-track upload the real
// song name is what follows the episode marker, not the collection title.
function songAfterEpisode(text) {
  const value = String(text);
  EPISODE_RE.lastIndex = 0;
  const match = EPISODE_RE.exec(value);
  EPISODE_RE.lastIndex = 0;
  if (!match) return '';
  const tail = value.slice(match.index + match[0].length);
  if (!tail || !/^[\s\-–—:：|｜.]+/.test(tail)) return '';
  return tail.replace(/^[\s\-–—:：|｜.]+/, '').trim();
}

// `壱雫空 - MyGO!!!!!｜Divide⧸Unite` / `Tokyo - Owl City`: the song sits on one
// side of a full-width bar or a spaced dash; `Hi-Res` and `EXO-K` stay whole.
function splitSongSlot(title) {
  const bar = /\s*[|｜]\s*/.exec(title);
  if (bar) {
    return {
      before: title.slice(0, bar.index),
      left: title.slice(0, bar.index),
      right: title.slice(bar.index + bar[0].length),
    };
  }
  const dash = /\s+[-\u2013\u2014\uFF0D]\s*/.exec(title);
  if (dash) {
    return {
      before: title.slice(0, dash.index),
      left: title.slice(0, dash.index),
      right: title.slice(dash.index + dash[0].length),
    };
  }
  return { before: '', left: '', right: '' };
}

function pickSongName(candidates, raw, episodeName, slotLeft, slotRight, strong) {
  const rawText = String(raw);
  let best = '';
  let bestScore = -Infinity;
  for (const candidate of candidates) {
    if (!isSongLike(candidate)) continue;
    let score = 0;
    if (candidate.length <= 24) score += 2;
    if (candidate.length > 30) score -= 2 + (candidate.length - 30) / 10;
    if (candidate.length <= 3) score -= 1;
    else if (candidate.length >= 6) score += 1;
    // `《明日方舟》EP - What an Electromagnetic Night`: a short all-caps token
    // that sits right before the separator is a release label, not the song.
    if (/^[A-Z]{2,4}$/.test(candidate) && new RegExp(`(?:^|[\\s|｜\\-\\u2013\\u2014\\uFF0D:：》」』）)])${candidate}\\s*-\\s`).test(rawText)) score -= 6;
    const isSlotSide = candidate === slotLeft || candidate === slotRight;
    // A descriptor such as `4K 60 动态水印` is never the song; a real title may
    // legitimately contain one of these words.
    if (SONG_DESC_RE.test(candidate) && !(isSlotSide && candidate.length >= 8)) score -= 3;
    if (/第\s*[0-9一二三四五六七八九十]+\s*[季期部波]/.test(candidate)) score -= 4;
    if (rawText.includes(candidate)) score += 1;
    if (candidate === rawText.trim()) score -= 2;
    if (episodeName && candidate === episodeName) score += 6;
    if (strong.has(candidate)) score += 4;
    // In `Tokyo - Owl City` the right side is a title-case artist credit, while
    // `What an Electromagnetic Night` on the right is the song itself.
    const artistLike = /^[A-Z][A-Za-z0-9.!'&,-]*(?:\s+[A-Z][A-Za-z0-9.!'&,-]*)+$/.test(candidate);
    if (isSlotSide && (strong.has(candidate) || (candidate.length >= 6 && !artistLike))) score += 2;
    // `Tokyo - Owl City`, `ZEAL of proud - Roselia`: with no CJK anywhere, the
    // left side of the slot is the song and the right side is the artist credit.
    const bothLatin = slotLeft && slotRight
      && !/[\u3400-\u9fff\u3040-\u30ff]/.test(slotLeft + slotRight);
    if (bothLatin && candidate === slotLeft) score += 2;
    if (bothLatin && artistLike) score -= 4;
    // `霜雪千年 - 双笙&封茗囧菌`, `音阙诗听×李佳思 - 流浪的猫写情诗`: an `X&Y` or
    // `X×Y` credit list on one side means the other side is the song. Without
    // `×` the artist line won and the row showed a singer as its title.
    if (slotLeft && slotRight && /[&＆×✕╳]/.test(candidate)) {
      const other = candidate === slotLeft ? slotRight : slotLeft;
      if (other && !/[&＆×✕╳]/.test(other)) score -= 5;
    }
    // `「壱雫空」- MyGO!!!!!`: a song in quotation marks outranks the artist
    // that merely stands in the `Song - Artist` slot.
    if (!isSlotSide && /[\u300C\u300E]/.test(rawText.split(candidate)[0] || '')) score += 3;
    // In `Song - Artist` the left side is the song and the right side is the
    // artist, so the left side wins a tie.
    if (candidate === slotLeft) score += 2;
    else if (candidate === slotRight) score += 2;
    // `What an Electromagnetic Night` is a title; the bare label `EP` is not.
    if (/[\u3400-\u9fff\u3040-\u30ff]/.test(candidate)) score += 2;
    if (score > bestScore || (score === bestScore && candidate.length < best.length)) { best = candidate; bestScore = score; }
  }
  return best;
}

// `《明日方舟》EP - Follow Your Heart`, `Roselia 14th single—「Call the shots」`
// — the bracketed text is the release, not the song, so it must not win.
// `《画风（《天行九歌》片尾曲）》` keeps its title inside the bracket and only
// describes it afterwards, so a nested bracket is not a release marker.
function describeAfter(title, end) {
  const after = title.slice(end + 1);
  if (/^\s*[（(]/.test(after)) return true;
  if (SONG_BRACKET_RE.test(after.slice(0, 2))) return false;
  return /^\s*(?:ep|album|ost|single|ver|version|remix)\b/i.test(after)
    || /^\s*[\u3400-\u9fff]{0,4}\s*(?:新歌|专辑|曲目|主题曲|片尾曲|插曲|推广曲)/.test(after);
}

// `BEYOND《冷雨夜》` / `『倾国』“铁衣踏不过”`: the bracketed run is the song and
// the text beside it is an artist, a lyric quote or a comment on the track.
// `「猫头鹰之城」Fireflies 萤火虫 - Owl City` is the opposite: the bracket holds
// the album, and the Latin title outside it is the song.
function bracketIsSong(title, bracket, content) {
  const after = title.slice(bracket.end + 1);
  if (!after || /^[\s\-–—:：|｜.）)。，,、]*$/.test(after)) return true;
  const before = stripNoise(stripBrackets(title.slice(0, bracket.start)));
  // `「猫头鹰之城」Fireflies 萤火虫 - Owl City`: nothing precedes the bracket and a
  // Latin title follows it, so the bracket holds the album, not the song.
  if (!before && /^[\s\-–—:：|｜.]*[A-Za-z]{2}/.test(after) && !/[A-Za-z]/.test(content)) return false;
  return true;
}

// A bracketed run that contains a book/quotation title is part of the title
// text itself (`【附歌词中字】【FULL】Roselia-「Always recall.」`), not a label.
function bracketTitle(content) {
  if (SONG_BRACKET_RE.test(content)) return '';
  if (bracketCandidates(content).length) return '';
  // `《画风（《天行九歌》片尾曲）》` truncates at the first closing bracket, so an
  // unbalanced run is not a title at all.
  if ((content.match(/[\u300A\u300C\u300E]/g) || []).length !== (content.match(/[\u300B\u300D\u300F]/g) || []).length) return '';
  const cleaned = stripNoise(stripBrackets(content));
  if (!isSongLike(cleaned)) return '';
  if (!/[\u3400-\u9fff\u3040-\u30ffa-z]/i.test(cleaned)) return '';
  if (SONG_DESC_RE.test(cleaned) && cleaned.length >= 8) return '';
  if (/^第\s*[0-9一二三四五六七八九十]+\s*[季期部波]/.test(cleaned)) return '';
  return cleaned;
}

// `小树 - 向日葵人生-动漫《我叫MT 第三季》`: a bracket that only names the
// collection is dropped so the dash segments around it stay adjacent.
function dropCollection(title) {
  let value = String(title);
  for (const pair of BRACKET_PAIRS) {
    let from = 0;
    for (;;) {
      const start = value.indexOf(pair.open, from);
      if (start < 0) break;
      const end = value.indexOf(pair.close, start + 1);
      if (end < 0) break;
      const content = value.slice(start + 1, end);
      if (/第\s*[0-9一二三四五六七八九十]+\s*[季期部波]/.test(content)) {
        value = `${value.slice(0, start)} ${value.slice(end + 1)}`;
        from = start;
        continue;
      }
      from = end + 1;
    }
  }
  return value.replace(/\s+/g, ' ').trim();
}

function cleanSongName(raw) {
  if (!raw) return '';
  const title = dropCollection(String(raw).trim());
  const brackets = bracketCandidates(title);
  const candidates = [];
  const strong = new Set();

  // `… p02 Ringing Bloom`: inside a multi-track upload the real song name is
  // what follows the episode marker, and it outranks every bracketed title.
  const episodeName = stripNoise(stripBrackets(songAfterEpisode(title)));
  if (episodeName && isSongLike(episodeName)) return episodeName;

  // A quoted song title is the strongest signal in this library, so the
  // `Song - Artist` split is only consulted when no such title exists.
  const slot = splitSongSlot(title);
  const slotLeft = slot.left ? stripNoise(stripBrackets(slot.left)) : '';
  const slotRight = slot.right ? stripNoise(stripBrackets(slot.right)) : '';
  // `小树 - 向日葵人生-动漫《我叫MT 第三季》` keeps the song in one dash segment.
  // A bare `-` glued to words stays whole, so `ZEAL of proud - Roselia` splits
  // while `Hi-Res`, `EXO-K` and `Hello-Goodbye` do not.
  const dashParts = title
    .split(/\s*[|｜]\s*|\s+[-\u2013\u2014\uFF0D]\s*|(?<=[\u3400-\u9fff\uf900-\ufaff])[-\u2013\u2014\uFF0D](?=[\u3400-\u9fff\uf900-\ufaff])/)
    .map((part) => stripNoise(stripBrackets(part)))
    .filter((part) => isSongLike(part) && !/^\d+$/.test(part));
  // `杜婧荧 &王艺翔-雪-动漫《我叫MT 第三季》`: with several dash segments before
  // the bracket, the song is the segment nearest to it.
  const localParts = title
    .slice(0, brackets.length ? brackets[0].start : title.length)
    .split(/[-\u2013\u2014\uFF0D|｜]/)
    .map((part) => stripNoise(stripBrackets(part)))
    .filter((part) => isSongLike(part) && !NOISE_RES.some((re) => re.test(part)));
  const slotNearest = localParts.length >= 3 ? localParts[localParts.length - 1] : '';
  let hasQuotedTitle = false;

  // The `·` subtitle never holds the song, so its head is a strong candidate for
  // the segments a bracket did not already settle. Strong candidates also evict
  // the full run from the pool below, which is what keeps the tail from winning.
  for (const value of [slotLeft, slotRight, stripNoise(stripBrackets(title))]) {
    const head = dotTruncatedHead(value);
    if (head && !strong.has(value)) { candidates.push(head); strong.add(head); }
  }

  // Fallback 1: bracketed titles, in bracket order, skipping release/album runs.
  for (const bracket of brackets) {
    // `画风（《天行九歌》片尾曲）`: the title is cut short because a nested bracket
    // closes first, and what follows it is a description, not the song.
    const nested = /[\u300A\u300B\u300C\u300D\u300E\u300F]/.exec(bracket.content);
    if (nested && !bracketCandidates(bracket.content).length) {
      // `画风（《天行九歌》片尾曲）`: the outer title was cut short because a
      // nested bracket closed first, and what follows it is a description.
      const head = stripNoise(stripBrackets(bracket.content.slice(0, nested.index)));
      if (isSongLike(head)) { candidates.push(head); strong.add(head); }
      const prefix = stripNoise(stripBrackets(title.slice(0, bracket.start)));
      if (prefix && isSongLike(prefix)) candidates.push(prefix);
      const full = stripNoise(stripBrackets(title));
      if (isSongLike(full)) candidates.push(full);
      continue;
    }
    // `杜婧荧 &王艺翔-雪-动漫《我叫MT 第三季》`: the bracket merely names the
    // collection; `dropCollection` removed it before this loop began.
    if (/第\s*[0-9一二三四五六七八九十]+\s*[季期部波]/.test(bracket.content)) continue;
    if (describeAfter(title, bracket.end)) continue;
    const content = bracketTitle(bracket.content);
    if (content && content.length <= 40 && bracketIsSong(title, bracket, content)) {
      candidates.push(content);
      strong.add(content);
      if (/[\u300C\u300E]/.test(title.slice(0, bracket.start))) hasQuotedTitle = true;
      const head = content.replace(/[（(][^）)]*[）)]/g, ' ').trim();
      if (head && head !== content) { candidates.push(head); strong.add(head); }
      continue;
    }
    // `壱雫空 - MyGO!!!!!` or `《可惜没如果》德国钢琴家…`: the bracketed text is
    // not the song, and the preceding segment is where the song lives. A prefix
    // that still carries `Song - Artist` punctuation is not a title either.
    const prefix = stripNoise(stripBrackets(title.slice(0, bracket.start)));
    if (prefix && isSongLike(prefix) && !/\s[-\u2013\u2014\uFF0D]\s/.test(prefix)) candidates.push(prefix);
    // Only when the bracket itself turned out not to be the title.
    if (!content && slotNearest && slotNearest !== prefix && isSongLike(slotNearest)) { candidates.push(slotNearest); strong.add(slotNearest); }
    const full = stripNoise(stripBrackets(title));
    if (isSongLike(full)) candidates.push(full);
  }

  // Fallback 2: the segment in the "song slot", i.e. after a `｜` or a dash.
  if (!hasQuotedTitle) {
    for (const value of [slotLeft, slotRight]) {
      if (value && isSongLike(value)) candidates.push(value);
    }
  }

  const strippedNoise = stripNoise(stripBrackets(title));
  if (strippedNoise) {
    candidates.push(strippedNoise);
    const cut = cutDescriptiveTail(strippedNoise);
    if (cut !== strippedNoise) candidates.push(cut);
    if (strippedNoise.includes(' | ')) {
      const head = strippedNoise.split(' | ')[0].trim();
      if (head) candidates.push(head);
    }
  }
  // `小树 - 向日葵人生-动漫《我叫MT 第三季》` keeps the song in one dash segment.
  // A bare `-` glued to words stays whole, so `ZEAL of proud - Roselia` splits
  // while `Hi-Res`, `EXO-K` and `Hello-Goodbye` do not.
  for (const part of title
    .split(/\s*[|｜]\s*|\s+[-\u2013\u2014\uFF0D]\s*|(?<=[\u3400-\u9fff\uf900-\ufaff])[-\u2013\u2014\uFF0D](?=[\u3400-\u9fff\uf900-\ufaff])/)
    .map((value) => stripNoise(stripBrackets(value)))) {
    if (isSongLike(part) && !/^\d+$/.test(part)) candidates.push(part);
  }
  // `后弦《画风（《天行九歌》片尾曲）》…`: nested brackets defeat the extraction,
  // so the cleaned whole title must still be in play.
  if (!brackets.length) {
    const whole = stripNoise(stripBrackets(title));
    if (isSongLike(whole)) candidates.push(whole);
  }

  // `Fireflies 萤火虫 - Owl City` must not hide the album- and artist-free title
  // that the filename already offered in one of its segments.
  const pool = candidates.filter((candidate) => ![...strong].some((other) => other !== candidate
    && other.length >= 2 && other.length < candidate.length && candidate.includes(other)));

  const chosen = pickSongName(pool, title, episodeName, slotLeft, slotRight, strong);
  if (chosen) {
    // `Fireflies 萤火虫 - Owl City`: once the song is known, a trailing Latin
    // ` - Artist` credit next to CJK text is not part of its name.
    const trimmed = chosen.replace(/([\u3400-\u9fff\u3040-\u30ff])[\s]*[-\u2013\u2014\uFF0D|｜][\s]*([A-Za-z][A-Za-z0-9 .!&,'-]*)$/, '$1').trim();
    return isSongLike(trimmed) ? trimmed : chosen;
  }
  // Never invent a placeholder: an unreadable title still identifies its file.
  const fallback = stripNoise(stripBrackets(title));
  return fallback || title;
}

// A row already knows its singer, so a title that carries the credit beside the
// song can be cut from that fact instead of guessing which side of a dash holds
// the song. Two real shapes need it: a credit glued with a bare `-`
// (`光年之外-G.E.M.邓紫棋`, which the CJK/Latin dash rule above deliberately never
// splits) and a credit in front of a short song name (`周杰伦 - 七里香`, where the
// song and the singer tie on candidate score and candidate order decides, so the
// singer sometimes won). Only a whole segment that *is* the singer counts, and the
// separator that joined it leaves with it, so the remainder keeps the shape
// cleanSongName() already understands. Returns '' when no segment is that singer,
// which leaves the title on the existing path.
// A segment boundary is a full-width bar, a spaced dash, or a dash glued to CJK
// text or to a bracket: `EXO-K`, `Hi-Res` and `Hello-Goodbye` stay whole, while
// `光年之外-G.E.M.邓紫棋` and `Steve Vai （史蒂夫 范）- for the love of god` split.
const SONG_CREDIT_SEPARATOR = /\s*[|｜]\s*|\s+[-\u2013\u2014\uFF0D]\s*|(?<=[\u3400-\u9fff\u3040-\u30ff\uf900-\ufaff\s\uFF09\u3011\u300D\u300F\u300B\]])[-\u2013\u2014\uFF0D]|[-\u2013\u2014\uFF0D](?=[\u3400-\u9fff\u3040-\u30ff\uf900-\ufaff\s\uFF08(\u3010\u300C\u300E\u300A\[])/g;

function stripSingerCredit(rawTitle, singer) {
  const title = String(rawTitle || '').trim();
  const name = String(singer || '').trim();
  if (!title || name.length < 2) return '';
  const normalize = (value) => String(value || '').replace(/\s+/g, ' ').trim().toLowerCase();
  const target = normalize(name);
  const separator = new RegExp(SONG_CREDIT_SEPARATOR.source, 'g');
  const segments = [];
  let cursor = 0;
  let match;
  while ((match = separator.exec(title)) !== null) {
    segments.push({ start: cursor, end: match.index, separatorEnd: match.index + match[0].length });
    cursor = match.index + match[0].length;
  }
  if (!segments.length) return '';
  segments.push({ start: cursor, end: title.length, separatorEnd: title.length });
  for (let index = 0; index < segments.length; index += 1) {
    const segment = segments[index];
    const text = title.slice(segment.start, segment.end);
    if (normalize(stripNoise(stripBrackets(text))) !== target) continue;
    // A credit in front takes its following separator with it; a credit at the end
    // takes the preceding one.
    const from = index === 0 ? segment.start : segments[index - 1].end;
    const to = index === 0 ? segment.separatorEnd : segment.end;
    const rest = `${title.slice(0, from)} ${title.slice(to)}`.replace(/\s+/g, ' ').trim();
    return rest.replace(/^[-\u2013\u2014\uFF0D|｜\s]+|[-\u2013\u2014\uFF0D|｜\s]+$/g, '').trim();
  }
  return '';
}

function formatTrackDisplay(item) {
  const rawTitle = item?.title || item?.name || '';
  const rawArtist = item?.artist || '';
  // Traditional (the default) shows what the folder itself says: the file's own
  // name and the indexed singer, with no derived album or year. The server keeps
  // those original values in raw_* because `artist`/`album` carry the resolved
  // ones; a row without them (an online recommendation) is already raw.
  if (state.displayMode !== 'canonical') {
    return {
      title: rawTitle || '未命名歌曲',
      artist: String(item?.raw_artist ?? rawArtist ?? '').trim(),
      album: '',
      year: '',
    };
  }
  // Cut the row's own singer out of the title before regularizing what is left:
  // `周杰伦 - 七里香` must show `七里香`, not the singer.
  const credited = stripSingerCredit(rawTitle, rawArtist) || stripSingerCredit(rawTitle, String(item?.raw_artist || ''));
  // Once the singer is gone, a trailing marker word left over from the file name
  // (`… - for the love of god（上帝的爱）live`) is re-expressed as the `(Live)` /
  // `(Cover)` suffix below instead of staying glued to the song name.
  const cleanedCredit = credited ? credited.replace(TAIL_MARKER_RE, '').trim() : '';
  const title = cleanSongName(cleanedCredit || credited || rawTitle) || '未命名歌曲';
  // Detect Live/Cover tags from the original title, but never from a comment
  // tail (the `pXX` episode number marks the real track inside a compilation).
  const tail = EPISODE_RE.test(rawTitle) ? '' : rawTitle.replace(/^.*\uFF5C/, '');
  EPISODE_RE.lastIndex = 0;
  const isLive = LIVE_RE.test(tail);
  const isCover = COVER_RE.test(tail);
  const isCoverRaw = /翻唱/.test(tail);
  let displayTitle = title;
  if (isLive && !LIVE_RE.test(displayTitle)) displayTitle += ' (Live)';
  if ((isCover || isCoverRaw) && !COVER_RE.test(displayTitle) && !/翻唱/.test(displayTitle)) displayTitle += ' (Cover)';
  return {
    title: displayTitle,
    artist: String(rawArtist || '').trim(),
    album: String(item?.album || '').trim(),
    year: yearLabel(item?.year),
  };
}

const PLAYBACK_MIN_SECONDS = 30;
const PLAYBACK_MIN_RATIO = 0.25;

const refreshes = new Map();
const pendingLikes = new Set();
const pendingDislikes = new Set();

// The release year only ever comes from NetEase's album publish date. It is blank
// when unknown rather than falling back to the file's own year tag, which for
// Bilibili downloads holds the upload year and would be a confidently wrong claim.
function yearLabel(value) {
  const year = Number(value);
  return Number.isFinite(year) && year > 1900 ? `${year} 年` : '';
}
async function fetchJson(url, options = {}) {
  const controller = new AbortController();
  const cancel = () => controller.abort();
  if (options.signal?.aborted) cancel();
  options.signal?.addEventListener('abort', cancel, { once: true });
  const timer = setTimeout(cancel, 12000);
  try {
    const response = await fetch(url, { ...options, cache: 'no-store', signal: controller.signal });
    let payload;
    try {
      payload = await response.json();
    } catch (error) {
      if (controller.signal.aborted || error?.name === 'AbortError') throw error;
      throw new Error(`服务返回非 JSON 响应 (${response.status})`);
    }
    if (!response.ok) throw new Error(payload?.message || `请求失败 (${response.status})`);
    return payload;
  } finally {
    clearTimeout(timer);
    options.signal?.removeEventListener('abort', cancel);
  }
}

function refreshOnce(key, action) {
  if (refreshes.has(key)) return refreshes.get(key);
  const pending = Promise.resolve().then(action).finally(() => refreshes.delete(key));
  refreshes.set(key, pending);
  return pending;
}

function replaceList(list, html) {
  const focused = document.activeElement;
  const row = list.contains(focused) ? focused.closest('article') : null;
  const attribute = row?.hasAttribute('data-library-id') ? 'data-library-id' : 'data-track-id';
  const id = row?.getAttribute(attribute);
  const action = focused?.getAttribute('data-action');
  const scrollTop = list.scrollTop;
  list.innerHTML = html;
  list.scrollTop = scrollTop;
  if (id && action) list.querySelector(`[${attribute}="${CSS.escape(id)}"] [data-action="${CSS.escape(action)}"]`)?.focus({ preventScroll: true });
}

function setLyricsOpen(open, returnFocus = false) {
  $('#lyrics-panel').hidden = !open;
  $('#lyrics-toggle').setAttribute('aria-expanded', String(open));
  if (returnFocus) $('#lyrics-toggle').focus();
}

function setPlaybackStatus(message) { $('#playback-status').textContent = message; }

function newPlaybackSessionId() {
  if (globalThis.crypto && crypto.randomUUID) return crypto.randomUUID();
  return `${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

function localIdOf(item) {
  return localIdFromItem(item);
}

function isLocalPlayable(item) {
  return Boolean(localIdOf(item) && (item?.local_status === 'LOCAL' || item?.source === 'local' || item?.provider === 'navidrome' || String(item?.stream_url || '').includes('/api/library/')));
}

function showToast(message) {
  const toast = $('#toast'); toast.textContent = message; toast.classList.add('show');
  clearTimeout(showToast.timer); showToast.timer = setTimeout(() => toast.classList.remove('show'), 2200);
}

function filteredLibrary() {
  const query = state.searchQuery;
  const items = query ? state.library.filter((item) => item.searchText.includes(query)) : state.library;
  return globalThis.MusicTreeUI ? globalThis.MusicTreeUI.filterLibrary(items) : items;
}

// Sort displayed library items. 'added' sorts newest-added first using the
// file modification time carried in item.addedto / item.collectionat.
function sortLibraryVisible(visible) {
  if (state.librarySort !== 'added') return visible;
  const byTime = (item) => {
    const t = item?.addedto || item?.collectionat || '';
    if (!t) return 0;
    const ms = Date.parse(t);
    if (Number.isFinite(ms)) return ms;
    // Fallback: parse "MM/dd/yyyy HH:mm:ss" (local) which some browsers reject
    // via Date.parse. Build a Date from parts to be safe.
    const m = /^(\d{1,2})\/(\d{1,2})\/(\d{4})[ T](\d{1,2}):(\d{2})(?::(\d{2}))?/.exec(t);
    if (m) {
      const d = new Date(Number(m[3]), Number(m[1]) - 1, Number(m[2]), Number(m[4]), Number(m[5]), Number(m[6] || 0));
      return d.getTime();
    }
    return 0;
  };
  return [...visible].sort((a, b) => byTime(b) - byTime(a));
}

function shuffled(items) {
  const result = [...items];
  for (let index = result.length - 1; index > 0; index -= 1) {
    const swapIndex = Math.floor(Math.random() * (index + 1));
    [result[index], result[swapIndex]] = [result[swapIndex], result[index]];
  }
  return result;
}

function orderByKeys(items, keys) {
  const byKey = new Map(items.map((item) => [keyOf(item), item]));
  const ordered = keys.map((key) => byKey.get(String(key))).filter(Boolean);
  const kept = new Set(ordered.map(keyOf));
  return [...ordered, ...items.filter((item) => !kept.has(keyOf(item)))];
}

function persistLibraryOrder() {
  state.libraryOrder = state.library.map(keyOf);
  localStorage.setItem('musicserver-library-order', JSON.stringify(state.libraryOrder));
}

function syncLibrary(items) {
  const incoming = Array.isArray(items) ? items.map(normalizeLibraryItem) : [];
  // Search covers both vocabularies: in traditional mode the listener types what
  // the folder shows, and the same row must still be findable by the resolved
  // name (and vice versa) after switching modes.
  incoming.forEach((item) => { item.searchText = [item.title, item.name, item.artist, item.raw_artist, item.album, item.raw_album].map((value) => String(value || '').toLocaleLowerCase()).join('\n'); });
  state.librarySequence = incoming;
  if (state.mode === 'random' && state.libraryOrder.length) {
    state.library = orderByKeys(incoming, state.libraryOrder);
    persistLibraryOrder();
    return;
  }
  if (state.mode !== 'random') {
    state.library = incoming;
    return;
  }

  state.mode = 'sequence';
  localStorage.setItem('musicserver-play-mode', state.mode);
  state.libraryOrder = [];
  state.library = incoming;
}

function setPlaybackMode(mode) {
  if (mode !== 'sequence') return;
  state.mode = 'sequence';
  localStorage.setItem('musicserver-play-mode', state.mode);
  state.libraryOrder = [];
  localStorage.removeItem('musicserver-library-order');
  state.library = [...state.librarySequence];
  render();
}

function reshuffleLibrary() {
  const source = state.librarySequence.length ? state.librarySequence : state.library;
  if (!source.length) { showToast('音乐库还在同步，请稍后再随机'); return; }
  state.mode = 'random';
  state.library = shuffled(source);
  localStorage.setItem('musicserver-play-mode', state.mode);
  persistLibraryOrder();
  render();
  showToast('已重新随机排列播放列表');
}

function renderLibrary() {
  const list = $('#library-list'); if (!list) return;
  const matches = sortLibraryVisible(filteredLibrary());
  const visible = matches.slice(0, state.libraryLimit);
  $('#library-count').textContent = state.searchQuery ? `找到 ${matches.length} 首` : `${state.library.length} 首`;
  $('#library-more').hidden = matches.length <= visible.length;
  $('#library-more').textContent = `显示更多（${visible.length} / ${matches.length}）`;
  $('#library-nav-count').textContent = state.library.length;
  $('#local-count').textContent = state.library.length;
  if (globalThis.MusicTreeUI) {
    globalThis.MusicTreeUI.renderLibrary({ items: matches, total: state.library.length,
      searchQuery: state.searchQuery, librarySort: state.librarySort, displayMode: state.displayMode,
      currentKey: state.currentKey, paused: $('#audio-player').paused, display: formatTrackDisplay, keyOf,
      refresh: () => { renderLibrary(); updateNavigationButtons(); } });
    return;
  }
  if (!state.library.length) { list._sig = null; list.innerHTML = '<div class="empty-state">曲库还是空的。<br />从右侧推荐开始，点红心收藏喜欢的音乐。</div>'; return; }
  if (!visible.length) { list._sig = null; list.innerHTML = '<div class="empty-state">没有找到匹配的歌曲。<br />试试歌手名，或清空搜索。</div>'; return; }
  const signature = JSON.stringify(visible.map((item) => [keyOf(item), state.currentKey === keyOf(item), $('#audio-player').paused, item.starred, item.source, item.title, item.artist, item.raw_artist, item.album, item.duration, state.displayMode]));
  if (list._sig === signature && !list._dirty) return;
  list._sig = signature;
  list._dirty = false;
  replaceList(list, visible.map((item) => {
    const playing = state.currentKey === keyOf(item);
    const display = formatTrackDisplay(item);
    const meta = [display.artist, display.year, display.album].filter(Boolean).join(' · ');
    return `<article class="track-row library-row ${playing ? 'playing' : ''}" data-library-id="${escapeHtml(item.id)}">
      <button class="play-button" data-action="play" aria-label="${playing && !$('#audio-player').paused ? '暂停' : '播放'} ${escapeHtml(display.title)}">${playing && !$('#audio-player').paused ? '❚❚' : '▶'}</button>
      <div class="track-main"><div class="track-title" title="${escapeHtml(display.title)}">${escapeHtml(display.title)}</div><div class="track-artist">${escapeHtml(meta)}</div></div>
      <span class="library-mark">${item.starred ? '♥' : (item.source === 'DailyMix' ? '今日' : '')}</span>
      <span class="track-duration">${duration(item.duration)}</span>
      <button class="lyrics-button" data-action="lyrics" aria-label="查看歌词">词</button>
      <button class="delete-button" data-action="delete" aria-label="删除这首歌" title="删除">✕</button>
    </article>`;
  }).join(''));
}

// The download panel reflects the whole wanted queue, not just today's
// recommendations: a failed or waiting download must stay visible even after
// the daily list is regenerated (the queue entry itself is never dropped).
function downloadExplanation(entry) {
  const reasons = { HTTP_412:'来源限流，冷却后重试', CIRCUIT_OPEN:'来源暂时冷却', BILIBILI_CIRCUIT_OPEN:'Bilibili 暂时冷却', NETEASE_NOT_AVAILABLE:'网易云未提供完整音源', NETEASE_REQUEST_FAILED:'网易云请求失败', NO_CANDIDATE:'未找到身份匹配的音源', ALL_CANDIDATES_FAILED:'本轮音源均未通过', WRONG_DURATION:'音源时长不符，已拒绝入库', WORKER_EXCEPTION:'处理异常，详见下载日志', DOWNLOAD_FAILED:'下载失败', NETEASE_DOWNLOAD_EMPTY:'音源为空或不完整' };
  const reason = reasons[entry.last_error] || entry.last_error || '';
  const attempts = Number(entry.attempt_count ?? entry.attempts ?? 0);
  const limit = Number(entry.max_attempts || 5);
  const parts = [reason, attempts > 0 ? `尝试 ${attempts}/${limit}` : ''];
  const retry = Date.parse(entry.next_retry_at || '');
  if (entry.state === 'RETRY_WAIT' && Number.isFinite(retry)) parts.push(`下次 ${new Date(retry).toLocaleTimeString([], {hour:'2-digit',minute:'2-digit'})}`);
  if (entry.state === 'UNAVAILABLE') parts.push('已停止自动重试，可手动重试');
  return parts.filter(Boolean).join(' · ');
}

function wantedQueueEntries() {
  const byId = new Map();
  for (const entry of (Array.isArray(state.wanted) ? state.wanted : [])) {
    const id = String(entry?.track_id || entry?.id || '');
    if (!id || !entry?.state || entry.state === 'LOCAL') continue;
    byId.set(id, entry);
  }
  for (const item of state.items) {
    const id = String(item?.track_id || '');
    if (!id || !item?.wanted?.state || item.wanted.state === 'LOCAL') continue;
    const existing = byId.get(id);
    if (!existing) byId.set(id, { ...item.wanted, track_id: id, title: item.title, artist: item.artist });
    else if (!existing.title) { existing.title = item.title; existing.artist = existing.artist || item.artist; }
  }
  return [...byId.values()];
}

function renderRecommendations() {
  const list = $('#recommendation-list');
  $('#recommendation-count').textContent = state.items.length;
  $('#hero-count').textContent = state.items.length;
  $('#play-first').disabled = !state.items.length;
  $('#liked-count').textContent = state.items.filter((item) => item.liked).length;
  $('#local-count').textContent = state.library.length;
  const wanted = wantedQueueEntries();
  $('#wanted-count').textContent = wanted.length;
  $('#queue-count').textContent = wanted.length;
  $('#wanted-list').innerHTML = wanted.length ? wanted.map((entry) => {
    const retryable = entry.state === 'UNAVAILABLE' || entry.state === 'RETRY_WAIT';
    const label = escapeHtml([entry.title, entry.artist].filter(Boolean).join(' · ') || entry.track_id || '未知曲目');
    const badge = `<span class="status-badge ${statusClass(entry.state)}">${escapeHtml(labels[entry.state] || entry.state)}</span>`;
    const retry = retryable ? `<button class="text-button wanted-retry" type="button" data-action="wanted-retry" data-track-id="${escapeHtml(entry.track_id || '')}">重试</button>` : '';
    return `<div class="wanted-row"><span>${label}<small class="download-explanation">${escapeHtml(downloadExplanation(entry))}</small></span>${badge}${retry}</div>`;
  }).join('') : '当前没有待下载或等待重试的歌曲。';
  if (globalThis.MusicTreeUI) {
    globalThis.MusicTreeUI.renderRecommendations({ items: state.items, display: formatTrackDisplay, keyOf,
      currentKey: state.currentKey, paused: $('#audio-player').paused, pendingLikes, pendingDislikes,
      likeCurrent: () => { const item = state.items.find((entry) => keyOf(entry) === state.currentKey); if (item) toggleLike(item); } });
    return;
  }
  if (!state.items.length) { list._sig = null; list.innerHTML = '<div class="empty-state">今天的推荐还在准备中。<br />先从音乐库选一首，或稍后刷新。</div>'; return; }
  const signature = JSON.stringify(state.items.map((item) => [item.track_id, item.liked, item.disliked, itemStatus(item), state.currentKey === keyOf(item), $('#audio-player').paused, item.title, item.artist, item.reason, item.duration, item.year, state.displayMode, pendingLikes.has(item.track_id), pendingDislikes.has(item.track_id)]));
  if (list._sig === signature && !list._dirty) return;
  list._sig = signature;
  list._dirty = false;
  replaceList(list, state.items.map((item) => {
    const status = itemStatus(item); const playing = state.currentKey === keyOf(item);
    const display = formatTrackDisplay(item);
    const meta = [display.artist, display.year, item.reason || '为你推荐'].filter(Boolean).join(' · ');
    return `<article class="track-row ${playing ? 'playing' : ''}" data-track-id="${escapeHtml(item.track_id)}">
      <button class="play-button" data-action="play" aria-label="${playing && !$('#audio-player').paused ? '暂停' : '播放'} ${escapeHtml(display.title)}">${playing && !$('#audio-player').paused ? '❚❚' : '▶'}</button>
      <div class="track-main"><div class="track-title">${escapeHtml(display.title)}</div><div class="track-artist">${escapeHtml(meta)}</div></div>
      <span class="status-badge ${statusClass(status)}">${escapeHtml(labels[status] || status)}</span>
      <span class="track-duration">${duration(item.duration)}</span>
      <button class="dislike-button ${item.disliked ? 'disliked' : ''}" data-action="dislike" ${pendingDislikes.has(item.track_id) ? 'disabled' : ''} aria-label="${item.disliked ? '取消讨厌' : '讨厌这首歌'}" aria-pressed="${item.disliked}" title="${item.disliked ? '取消讨厌' : '讨厌：以后少推荐这首'}">👎</button>
      <button class="heart-button ${item.liked ? 'liked' : ''}" data-action="like" ${pendingLikes.has(item.track_id) ? 'disabled' : ''} aria-label="${item.liked ? '取消喜欢' : '喜欢'}" aria-pressed="${item.liked}">${item.liked ? '♥' : '♡'}</button>
    </article>`;
  }).join(''));
  $('#play-first').disabled = !state.items[0];
}

function renderListening() {
  const mostList = $('#most-played-list');
  const rediscoverList = $('#rediscover-list');
  if (!mostList || !rediscoverList) return;
  const most = state.listening.mostPlayed || [];
  const activeLocalId = state.playbackSession?.libraryId || '';
  const rediscover = (state.listening.rediscover || []).filter((item) => !activeLocalId || localIdOf(item) !== activeLocalId);

  mostList.innerHTML = most.length
    ? most.map((item, index) => {
        const d = formatTrackDisplay(item);
        return `<article class="listening-row" data-listening-id="${escapeHtml(item.id || item.library_id || item.identity)}">
          <span class="listening-rank">${String(index + 1).padStart(2, '0')}</span>
          <button class="listening-play" data-action="play" type="button" aria-label="播放 ${escapeHtml(d.title)}">▶</button>
          <div class="listening-main"><div class="listening-title">${escapeHtml(d.title)}</div><div class="listening-artist">${escapeHtml(d.artist)}</div></div>
          <span class="listening-count">${Number(item.play_count || 0)} 次</span>
        </article>`;
      }).join('')
    : '<div class="listening-empty">播放满 30 秒后，这里会留下你的常听。</div>';

  rediscoverList.innerHTML = rediscover.length
    ? rediscover.map((item) => {
        const d = formatTrackDisplay(item);
        return `<article class="listening-row rediscover-row" data-listening-id="${escapeHtml(item.id || item.library_id || item.identity)}">
          <span class="rediscover-mark">✦</span>
          <button class="listening-play" data-action="play" type="button" aria-label="播放 ${escapeHtml(d.title)}">▶</button>
          <div class="listening-main"><div class="listening-title">${escapeHtml(d.title)}</div><div class="listening-artist">${escapeHtml(d.artist)}</div></div>
          <span class="listening-count">${Number(item.play_count || 0) ? `${Number(item.play_count)} 次` : '未播放'}</span>
        </article>`;
      }).join('')
    : '<div class="listening-empty">曲库里的歌都在等你重新发现。</div>';
}

function listeningCollection() {
  const items = [...(state.listening.mostPlayed || []), ...(state.listening.rediscover || [])];
  return [...new Map(items.map((item) => [keyOf(item), item])).values()];
}

function playbackCollection() {
  if (state.currentCollection === 'recommendations') return state.items;
  if (state.currentCollection === 'listening') return listeningCollection();
  return sortLibraryVisible(filteredLibrary());
}

function updateNavigationButtons() {
  const collection = playbackCollection();
  const disabled = !collection.length || !state.currentKey;
  $('#previous-button').disabled = disabled;
  $('#next-button').disabled = disabled;
}

function render() { renderLibrary(); renderRecommendations(); renderListening(); renderMode(); updateNavigationButtons(); }

function renderMode() {
  document.querySelectorAll('.mode-button').forEach((button) => button.classList.toggle('active', button.dataset.mode === state.mode));
  $('#shuffle-button').classList.toggle('active', state.mode === 'random');
  document.querySelectorAll('.mode-button').forEach((button) => button.setAttribute('aria-pressed', String(button.dataset.mode === state.mode)));
  $('#shuffle-button').setAttribute('aria-pressed', String(state.mode === 'random'));
}

function updatePlayer(item) {
  if (!item) return;
  const display = formatTrackDisplay(item);
  $('#player-title').textContent = display.title;
  $('#player-artist').textContent = display.artist;
  $('#player-art').textContent = item.local_status === 'LOCAL' || item.stream_url ? '♫' : '♪';
}

function parseLyrics(text) {
  const rows = [];
  String(text || '').split(/\r?\n/).forEach((line) => {
    const tags = [...line.matchAll(/\[(\d+):(\d+(?:\.\d+)?)\]/g)];
    const content = line.replace(/\[\d+:\d+(?:\.\d+)?\]/g, '').trim();
    tags.forEach((tag) => rows.push({ time: Number(tag[1]) * 60 + Number(tag[2]), text: content || '♪' }));
  });
  return rows.sort((a, b) => a.time - b.time);
}

function normalizeLyricsPayload(data) {
  const text = String(data?.text ?? data?.lyrics ?? '');
  const available = typeof data?.available === 'boolean' ? data.available : Boolean(text.trim());
  return {
    ...data,
    available,
    format: data?.format || (text ? 'lrc' : ''),
    text,
    quality: data?.quality || (available ? 'UNVERIFIED' : ''),
    message: data?.message || (available ? '' : '这首歌暂时没有找到可靠歌词。'),
  };
}

function renderLyrics(currentTime = 0) {
  const content = $('#lyrics-content');
  if (!state.lyrics.available) { content.innerHTML = `<div class="lyrics-empty">${escapeHtml(state.lyrics.message || '这首歌暂时没有找到可靠歌词。')}</div>`; return; }
  if (!state.lyrics.entries.length) { content.innerHTML = `<pre class="lyrics-plain">${escapeHtml(state.lyrics.text)}</pre>`; return; }
  let active = -1;
  state.lyrics.entries.forEach((entry, index) => { if (entry.time <= currentTime) active = index; });
  if (state.lyrics.activeIndex === active && content.querySelector('.lyric-line')) return;
  state.lyrics.activeIndex = active;

  // Only rebuild the DOM the first time. Thereafter, just move the .active class,
  // so a user selecting/copying lyrics text is never interrupted by a full
  // innerHTML rebuild (which would wipe the browser selection on the next line).
  if (!content.querySelector('.lyric-line')) {
    content.innerHTML = state.lyrics.entries.map((entry, index) => `<div class="lyric-line ${index === active ? 'active' : ''}">${escapeHtml(entry.text)}</div>`).join('');
  } else {
    const lines = content.querySelectorAll('.lyric-line');
    lines.forEach((line, index) => line.classList.toggle('active', index === active));
  }
  const activeLine = content.querySelector('.lyric-line.active');
  // Don't auto-scroll while the user is selecting text in the panel: an
  // auto-scroll would drag the selection anchor and make copying lyrics hard.
  if (activeLine && !isTextSelecting()) {
    activeLine.scrollIntoView({ block: 'center', behavior: 'smooth' });
  }
}

function isTextSelecting() {
  try {
    const sel = window.getSelection();
    if (!sel || sel.isCollapsed) return false;
    const range = sel.getRangeAt(0);
    if (!range) return false;
    // Only treat an in-panel selection as "selecting".
    const panel = $('#lyrics-content');
    return panel && (panel.contains(range.startContainer) || panel.contains(range.endContainer));
  } catch { return false; }
}

async function loadLyrics(url, open = true) {
  const requestId = ++state.lyricsRequest;
  state.lyricsController?.abort();
  state.lyricsController = new AbortController();
  state.lyrics = { available: false, format: '', text: '', entries: [], quality: '', message: '' };
  $('#lyrics-toggle').disabled = false;
  if (open) setLyricsOpen(true);
  $('#lyrics-content').innerHTML = '<div class="lyrics-empty">正在加载歌词…</div>';
  if (!url) { renderLyrics(); return; }
  try {
    const data = await fetchJson(url, { signal: state.lyricsController.signal });
    if (requestId !== state.lyricsRequest) return;
    const normalized = normalizeLyricsPayload(data);
    state.lyrics = { ...normalized, entries: normalized.available ? parseLyrics(normalized.text) : [] };
    renderLyrics($('#audio-player').currentTime || 0);
  } catch {
    if (requestId !== state.lyricsRequest) return;
    state.lyrics.message = '歌词加载失败，请稍后重试。';
    renderLyrics();
  }
}

function neteasePreviewUrl(id) {
  if (id === undefined || id === null || String(id).trim() === '') return '';
  return `https://music.163.com/song/media/outer/url?id=${encodeURIComponent(String(id).trim())}.mp3`;
}

function neteaseIdFromPlaybackValue(value) {
  const match = /^netease:(.+)$/i.exec(String(value || '').trim());
  return match ? match[1].trim() : '';
}

function neteasePreviewFromTrack(item) {
  const identifiers = Array.isArray(item?.track?.identifiers) ? item.track.identifiers : [];
  const netease = identifiers.find((identifier) => String(identifier?.type || '').toLowerCase() === 'netease' && identifier?.value);
  return netease ? neteasePreviewUrl(netease.value) : '';
}

function neteasePreviewFromRecommendation(item) {
  const recommendation = item?.recommendation;
  if (!recommendation) return '';
  const explicitId = recommendation.netease_id;
  if (explicitId !== undefined && explicitId !== null && String(explicitId).trim()) return neteasePreviewUrl(explicitId);
  const playbackId = neteaseIdFromPlaybackValue(recommendation.playback_source);
  return playbackId ? neteasePreviewUrl(playbackId) : '';
}

function resolvePlaybackSource(item) {
  const nestedPreview = Array.isArray(item?.track?.preview_sources)
    ? item.track.preview_sources.find((source) => source?.media_url || source?.url)
    : null;
  const recommendationPreview = Array.isArray(item?.recommendation?.preview_sources)
    ? item.recommendation.preview_sources.find((source) => source?.media_url || source?.url)
    : null;
  const playbackUrl = item?.playback_source && typeof item.playback_source === 'object'
    ? item.playback_source.url
    : '';
  const directPlaybackId = typeof item?.playback_source === 'string'
    ? neteaseIdFromPlaybackValue(item.playback_source)
    : '';
  return item?.stream_url
    || playbackUrl
    || item?.preview_source?.media_url
    || item?.preview_source?.url
    || recommendationPreview?.media_url
    || recommendationPreview?.url
    || nestedPreview?.media_url
    || nestedPreview?.url
    || (directPlaybackId ? neteasePreviewUrl(directPlaybackId) : '')
    || neteasePreviewFromRecommendation(item)
    || neteasePreviewFromTrack(item);
}

async function hydrateRecommendationPlayback(item) {
  if (!item?.track_id) return item;
  try {
    const details = await fetchJson(`/api/tracks/${encodeURIComponent(item.track_id)}`);
    if (details.track) item.track = details.track;
    if (details.recommendation) item.recommendation = details.recommendation;
    if (details.playback_source) item.playback_source = details.playback_source;
    if (details.local_status) item.local_status = details.local_status;
    if (details.playback_source?.type === 'local' && details.playback_source?.url) item.stream_url = details.playback_source.url;
  } catch {}
  return item;
}

function maybeRecordPlayback() {
  const audio = $('#audio-player');
  const session = state.playbackSession;
  if (!audio || !session || session.key !== state.currentKey || session.counted || session.pending || audio.paused) return;
  const current = Number(audio.currentTime || 0);
  const total = Number(audio.duration || 0);
  const previous = session.lastAudioTime;
  if (previous === null || previous === undefined) {
    session.lastAudioTime = current;
    return;
  }
  const delta = current - previous;
  if (delta >= 0 && delta <= 5) {
    session.playedSeconds += delta;
  } else if (delta < -0.5 || delta > 5) {
    // A large jump is a seek, not proof that the skipped section was heard.
    session.seeked = true;
  }
  session.lastAudioTime = current;
  const reachedThreshold = session.playedSeconds >= PLAYBACK_MIN_SECONDS
    || (!session.seeked && total > 0 && current >= total * PLAYBACK_MIN_RATIO);
  if (!reachedThreshold) return;

  session.pending = true;
  fetch(`/api/library/${encodeURIComponent(session.libraryId)}/play`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ session_id: session.sessionId }),
  }).then(async (response) => {
    const result = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(result.message || 'playback record failed');
    session.pending = false;
    session.counted = true;
    if (result.counted) loadListening(true);
  }).catch(() => {
    // Keep the session id so a retry is idempotent if the server committed the
    // event but the response was lost.
    session.pending = false;
  });
}

async function playItem(item, collection = 'library') {
  const requestId = ++state.playRequest;
  let key = keyOf(item); const audio = $('#audio-player');
  if (!key) return;
  if (state.currentKey === key && !audio.paused) { audio.pause(); return; }
  let source = resolvePlaybackSource(item);
  if (!source && item.track_id) {
    setPlaybackStatus('正在准备试听…');
    await hydrateRecommendationPlayback(item);
    if (requestId !== state.playRequest) return;
    source = resolvePlaybackSource(item);
    const hydratedKey = keyOf(item);
    if (hydratedKey) key = hydratedKey;
  }
  if (!source) { setPlaybackStatus(audio.paused ? '暂不可用 · 请选择其他歌曲' : '正在播放'); showToast('这首歌暂时没有可用试听源'); return; }
  const sourceUrl = new URL(source, window.location.href).href;
  const isNewTrack = state.currentKey !== key || audio.src !== sourceUrl || audio.ended;
  state.currentKey = key; state.currentCollection = collection; state.currentItem = item; updatePlayer(item); $('#library-list')._dirty = true; $('#recommendation-list')._dirty = true; render();
  const pt = $('#play-toggle');
  if (pt) pt.disabled = false;
  renderPlayerArt(item);
  if (isNewTrack) {
    audio.pause(); audio.currentTime = 0; audio.src = sourceUrl;
    updateProgressUI();
    state.playbackSession = isLocalPlayable(item)
      ? { key, libraryId: localIdOf(item), sessionId: newPlaybackSessionId(), pending: false, counted: false, playedSeconds: 0, lastAudioTime: 0, seeked: false }
      : null;
  } else if (isLocalPlayable(item) && !state.playbackSession) {
    state.playbackSession = { key, libraryId: localIdOf(item), sessionId: newPlaybackSessionId(), pending: false, counted: false, playedSeconds: 0, lastAudioTime: 0, seeked: false };
  }
  const lyricsUrl = collection === 'recommendations' && item.track_id
    ? `/api/tracks/${encodeURIComponent(item.track_id)}/lyrics`
    : item.lyrics_url || (item.track_id ? `/api/tracks/${encodeURIComponent(item.track_id)}/lyrics` : '');
  setPlaybackStatus('正在加载…');
  // Lyrics must not hold up audio or reopen a panel the listener closed.
  void loadLyrics(lyricsUrl, false);
  try { await audio.play(); } catch {
    if (requestId !== state.playRequest) return;
    setPlaybackStatus('播放失败 · 点击播放重试');
    showToast('试听源加载失败，点击播放按钮重试');
  }
}

function renderPlayerArt(item) {
  if (!item) return;
  if (globalThis.MusicTreeUI) { globalThis.MusicTreeUI.playerArt(item); return; }
  const art = $('#player-art');
  if (!art) return;
  const cover = item.cover_url || item.recommendation?.cover_url || item.track?.cover_url;
  if (cover) {
    art.innerHTML = `<span class="player-cover" style="background-image:url('${escapeHtml(cover)}')"></span>`;
  } else {
    const local = item.local_status === 'LOCAL' || item.stream_url;
    art.innerHTML = `<span>${local ? '♫' : '♪'}</span>`;
  }
}

function adjacentItem(direction) {
  const collection = playbackCollection();
  if (!collection.length) return null;
  const index = collection.findIndex((item) => keyOf(item) === state.currentKey);
  const nextIndex = index < 0 ? 0 : (index + direction + collection.length) % collection.length;
  return collection[nextIndex];
}

function nextItem() {
  const item = adjacentItem(1);
  if (item) playItem(item, state.currentCollection);
}

function previousItem() {
  const audio = $('#audio-player');
  if (audio.currentTime > 3) { audio.currentTime = 0; return; }
  const item = adjacentItem(-1);
  if (item) playItem(item, state.currentCollection);
}

async function toggleDislike(item) {
  const trackId = item.track_id;
  if (pendingDislikes.has(trackId)) return;
  const next = !item.disliked;
  pendingDislikes.add(trackId);
  item.disliked = next;
  render();
  showToast(next ? '已标记讨厌，以后会少推荐这首' : '已取消讨厌');
  try {
    const response = await fetch(`/api/tracks/${encodeURIComponent(trackId)}/dislike`, {
      method: next ? 'POST' : 'DELETE',
      headers: { 'Content-Type': 'application/json; charset=utf-8' },
      body: '{}',
    });
    let result = null;
    try { result = await response.json(); } catch {}
    if (!response.ok) {
      const detail = result?.message || result?.error || `${response.status} ${response.statusText}`;
      throw new Error(detail);
    }
    item.disliked = typeof result?.disliked === 'boolean' ? result.disliked : next;
  } catch (error) {
    item.disliked = !next;
    render();
    showToast(`讨厌操作失败：${String(error?.message || '未知错误')}`);
  } finally {
    pendingDislikes.delete(trackId);
    state.recommendationRevision++;
    renderRecommendations();
  }
}

async function toggleLike(item) {
  if (pendingLikes.has(item.track_id)) return;
  pendingLikes.add(item.track_id);
  state.recommendationRevision++;
  const next = !item.liked;
  item.liked = next;
  render();
  showToast(next ? '已喜欢，加入后台下载队列' : '已取消喜欢');
  try {
    const response = await fetch(`/api/tracks/${encodeURIComponent(item.track_id)}/like`, {
      method: next ? 'POST' : 'DELETE',
      headers: { 'Content-Type': 'application/json; charset=utf-8' },
      body: '{}',
    });
    let result = null;
    try { result = await response.json(); } catch {}
    if (!response.ok) {
      const detail = result?.message || result?.error || `${response.status} ${response.statusText}`;
      throw new Error(detail);
    }
    item.liked = typeof result?.liked === 'boolean' ? result.liked : next;
    // Like and dislike are one axis, so liking clears a dislike.
    if (item.liked) item.disliked = false;
    item.wanted = result?.wanted || null;
    if (!item.wanted) state.wanted = (Array.isArray(state.wanted) ? state.wanted : []).filter((entry) => String(entry?.track_id || entry?.id || '') !== String(item.track_id));
    render();
  } catch (error) {
    item.liked = !next;
    render();
    const detail = String(error?.message || '未知错误');
    showToast(`喜欢操作失败：${detail}`);
  } finally {
    pendingLikes.delete(item.track_id);
    state.recommendationRevision++;
    renderRecommendations();
  }
}

async function loadLibrary(silent = false) {
  return refreshOnce('library', async () => {
  const revision = state.libraryRevision;
  try {
    const payload = await fetchJson(silent ? '/api/library' : '/api/library?refresh=1');
    if (revision !== state.libraryRevision) return;
    if (!Array.isArray(payload.items)) throw new Error('Invalid library response');
    syncLibrary(payload.items); renderLibrary(); updateNavigationButtons();
  } catch { if (!silent) { if (!state.library.length) { $('#library-list')._sig = null; $('#library-list').innerHTML = '<div class="empty-state">暂时无法读取音乐库。<br />点击右上角刷新重试。</div>'; } showToast('音乐库同步失败，请刷新重试'); } }
  });
}

async function loadRecommendations(silent = false) {
  return refreshOnce('recommendations', async () => {
  const revision = state.recommendationRevision;
  try {
    const payload = await fetchJson('/api/recommendations/today');
    if (revision !== state.recommendationRevision || pendingLikes.size) return;
    if (!Array.isArray(payload.items)) throw new Error('Invalid recommendation response');
    state.items = payload.items;
    $('#last-updated').textContent = `推荐更新于 ${new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}`;
    const weekday = new Date().toLocaleDateString('zh-CN', { weekday: 'long' }).toUpperCase();
    const dateStr = new Date().toLocaleDateString('zh-CN', { month: 'long', day: 'numeric' });
    const eyebrow = $('#today-eyebrow');
    if (eyebrow) eyebrow.textContent = `${weekday} · ${dateStr} · MUSIC DISCOVERY`;
    $('#error-banner').hidden = true; renderRecommendations(); updateNavigationButtons();
    if (!silent && state.items.length) $('#play-first').disabled = false;
  } catch { $('#error-banner').textContent = '推荐暂时同步失败。可以继续播放已有音乐，点击右上角刷新重试。'; $('#error-banner').hidden = false; if (!silent) renderRecommendations(); }
  });
}

async function loadWanted(silent = false) {
  return refreshOnce('wanted', async () => {
    try {
      const payload = await fetchJson('/api/wanted');
      if (!Array.isArray(payload.items)) throw new Error('Invalid wanted response');
      state.wanted = payload.items;
      renderRecommendations();
      updateNavigationButtons();
    } catch { if (!silent) showToast('下载动态同步失败，请稍后刷新'); }
  });
}

async function loadListening(silent = false) {
  return refreshOnce('listening', async () => {
  try {
    const payload = await fetchJson('/api/listening/stats');
    state.listening = {
      mostPlayed: Array.isArray(payload.most_played) ? payload.most_played : [],
      rediscover: Array.isArray(payload.rediscover) ? payload.rediscover : [],
      loaded: true,
    };
    renderListening();
    updateNavigationButtons();
  } catch {
    if (!silent) {
      state.listening.loaded = false;
      renderListening();
    }
  }
  });
}

async function playRandomListening() {
  try {
    const suffix = state.lastRandomId ? `?exclude=${encodeURIComponent(state.lastRandomId)}` : '';
    const response = await fetch(`/api/listening/random${suffix}`, { cache: 'no-store' });
    if (!response.ok) throw new Error('random listening request failed');
    const item = await response.json();
    state.lastRandomId = item.id || item.library_id || item.identity;
    await playItem(item, 'listening');
  } catch {
    const source = state.library.filter((item) => keyOf(item) !== state.lastRandomId && keyOf(item) !== state.currentKey);
    if (!source.length) { showToast('本地曲库还没有可随机播放的歌曲'); return; }
    const item = shuffled(source)[0];
    state.lastRandomId = item.id;
    await playItem(item, 'listening');
  }
}

async function loadProviderStatus() {
  return refreshOnce('providers', async () => {
  try {
    const data = await fetchJson('/api/providers/status');
    const blocked = (data.items || []).filter((item) => String(item.provider || '').startsWith('bilibili_') && item.state === 'OPEN');
    if (blocked.length) {
      const names = blocked.map((item) => item.provider === 'bilibili_search' ? '搜索' : '下载').join(' / ');
      $('#provider-summary').textContent = `Bilibili ${names}冷却中 · 不影响试听`;
    } else {
      $('#provider-summary').textContent = '本地优先 · 音乐来源可用';
    }
  } catch { $('#provider-summary').textContent = '音乐来源状态暂不可用'; }
  });
}

$('#library-list').addEventListener('click', (event) => {
  const row = event.target.closest('[data-library-id]'); if (!row) return;
  const item = state.library.find((candidate) => candidate.id === row.dataset.libraryId); if (!item) return;
  if (event.target.closest('[data-action="lyrics"]')) loadLyrics(item.lyrics_url, true);
  else if (event.target.closest('[data-action="play"]')) playItem(item, 'library');
  else if (event.target.closest('[data-action="delete"]')) deleteLibraryItem(item);
});

function listeningItemById(id) {
  return listeningCollection().find((item) => String(item.id || item.library_id || item.identity) === String(id)) || null;
}

function handleListeningClick(event) {
  const row = event.target.closest('[data-listening-id]');
  if (!row) return;
  const item = listeningItemById(row.dataset.listeningId);
  if (item && event.target.closest('[data-action="play"]')) playItem(item, 'listening');
}

$('#most-played-list').addEventListener('click', handleListeningClick);
$('#rediscover-list').addEventListener('click', handleListeningClick);

async function deleteLibraryItem(item) {
  const title = item.title || item.name || '这首歌';
  if (!window.confirm(`确定要从音乐库删除「${title}」吗？\n\n将同时删除本地音频文件（含歌词），且不可恢复。`)) return;
  const id = item.id || item.track_id;
  if (!id) { showToast('无法识别要删除的歌曲'); return; }
  state.libraryRevision++;
  try {
    const response = await fetch(`/api/library/${encodeURIComponent(id)}`, { method: 'DELETE', cache: 'no-store' });
    const result = await response.json();
    if (!response.ok || !result.accepted) { throw new Error(result.message || '删除请求失败'); }
    state.library = state.library.filter((candidate) => (candidate.id || candidate.track_id) !== id);
    state.librarySequence = state.librarySequence.filter((candidate) => (candidate.id || candidate.track_id) !== id);
    state.libraryRevision++;
    if (state.mode === 'random') persistLibraryOrder();
    if (state.currentKey === keyOf(item)) {
      state.playRequest++;
      $('#audio-player').pause();
      $('#audio-player').removeAttribute('src');
      $('#audio-player').load();
      state.currentKey = null; state.playbackSession = null;
      $('#play-toggle').disabled = true;
      setPlaybackStatus('歌曲已移除');
    }
    showToast(result.message || '已删除');
    renderLibrary(); updateNavigationButtons();
  } catch (err) {
    showToast(`删除失败：${err.message || '请稍后重试'}`);
  }
}

$('#recommendation-list').addEventListener('click', (event) => {
  const row = event.target.closest('[data-track-id]'); if (!row) return;
  const item = state.items.find((candidate) => candidate.track_id === row.dataset.trackId); if (!item) return;
  if (event.target.closest('[data-action="like"]')) toggleLike(item);
  else if (event.target.closest('[data-action="dislike"]')) toggleDislike(item);
  else if (event.target.closest('[data-action="play"]')) playItem(item, 'recommendations');
});

let searchTimer;
let composingSearch = false;
function scheduleSearch() {
  clearTimeout(searchTimer);
  if (composingSearch) return;
  searchTimer = setTimeout(() => {
    state.searchQuery = $('#library-search').value.trim().toLocaleLowerCase();
    state.libraryLimit = 200;
    $('#library-list').scrollTop = 0;
    renderLibrary(); updateNavigationButtons();
  }, 150);
}
$('#library-search').addEventListener('input', scheduleSearch);
$('#library-search').addEventListener('compositionstart', () => { composingSearch = true; clearTimeout(searchTimer); });
$('#library-search').addEventListener('compositionend', () => { composingSearch = false; scheduleSearch(); });
$('#library-more').addEventListener('click', () => { state.libraryLimit += 200; renderLibrary(); });
$('#library-sort').addEventListener('change', (event) => {
  state.librarySort = event.target.value || 'default';
  localStorage.setItem('musicserver-library-sort', state.librarySort);
  renderLibrary(); updateNavigationButtons();
});
document.querySelectorAll('.mode-button').forEach((button) => button.addEventListener('click', () => {
  setPlaybackMode(button.dataset.mode);
}));
$('#shuffle-button').addEventListener('click', reshuffleLibrary);
$('#refresh-button').addEventListener('click', async () => {
  $('#refresh-button').disabled = true;
  $('#refresh-button').setAttribute('aria-busy', 'true');
  try { await Promise.all([loadLibrary(), loadRecommendations(), loadWanted(), loadListening(), loadProviderStatus()]); }
  finally { $('#refresh-button').disabled = false; $('#refresh-button').setAttribute('aria-busy', 'false'); }
});
$('#rediscover-button').addEventListener('click', () => loadListening());

// A failed or retried download stays in the queue until the user acts; give them
// an explicit way back in instead of making them unlike/re-like the track.
$('#wanted-list').addEventListener('click', async (event) => {
  const action = event.target?.getAttribute?.('data-action');
  if (action !== 'wanted-retry') return;
  const trackId = event.target.getAttribute('data-track-id');
  if (!trackId) return;
  event.target.disabled = true;
  try {
    const response = await fetch(`/api/wanted/${encodeURIComponent(trackId)}/retry`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=utf-8' },
      body: '{}',
    });
    if (!response.ok) throw new Error(`${response.status} ${response.statusText}`);
    showToast('已重新加入下载队列');
    await loadWanted();
  } catch (error) {
    event.target.disabled = false;
    showToast(`重试失败：${String(error?.message || '未知错误')}`);
  }
});
$('#random-listening-button').addEventListener('click', playRandomListening);

// Listening sidebar collapse / expand.
function setListeningCollapsed(collapsed) {
  const sb = $('#listening-sidebar');
  if (!sb) return;
  sb.classList.toggle('collapsed', collapsed);
  sb.classList.toggle('expanded', !collapsed);
  const handle = $('#listening-handle');
  if (handle) handle.hidden = !collapsed;
  document.querySelector('.app-shell').classList.toggle('listening-collapsed', collapsed);
  localStorage.setItem('musicserver-listening-collapsed', collapsed ? '1' : '0');
  $('#listening-toggle').setAttribute('aria-expanded', String(!collapsed));
}

$('#listening-collapse')?.addEventListener('click', () => setListeningCollapsed(true));
$('#listening-toggle').addEventListener('click', () => {
  const collapsed = $('#listening-sidebar').classList.contains('collapsed');
  setListeningCollapsed(!collapsed);
  if (collapsed) $('#listening-collapse').focus();
});
$('#queue-toggle').addEventListener('click', () => { $('#wanted').open = !$('#wanted').open; });
$('#wanted').addEventListener('toggle', () => $('#queue-toggle').setAttribute('aria-expanded', String($('#wanted').open)));
$('#listening-handle')?.addEventListener('click', () => {
  setListeningCollapsed(false);
  if (!state.listening.loaded) loadListening();
});
$('#play-first').addEventListener('click', () => state.items[0] && playItem(state.items[0], 'recommendations'));
$('#previous-button').addEventListener('click', previousItem);
$('#next-button').addEventListener('click', nextItem);
$('#lyrics-toggle').addEventListener('click', () => { setLyricsOpen($('#lyrics-panel').hidden); if (!$('#lyrics-panel').hidden) $('#lyrics-close').focus(); });
$('#lyrics-close').addEventListener('click', () => setLyricsOpen(false, true));
$('#volume-control').addEventListener('input', (event) => { $('#audio-player').volume = Number(event.target.value); });
document.addEventListener('keydown', (event) => {
  if (event.ctrlKey && event.key.toLowerCase() === 'k') { event.preventDefault(); $('#library-search').focus(); }
  if (event.key === 'Escape') {
    if (!$('#settings-panel').hidden) setSettingsOpen(false, true);
    else if (!$('#lyrics-panel').hidden) setLyricsOpen(false, true);
    else if (!$('#listening-sidebar').classList.contains('collapsed')) { setListeningCollapsed(true); $('#listening-toggle').focus(); }
    else if ($('#wanted').open) { $('#wanted').open = false; $('#queue-toggle').focus(); }
  }
});

// Custom play/pause control.
const DEFAULT_PLAY_ICON = '▶';
const DEFAULT_PAUSE_ICON = '❚❚';
const playToggle = $('#play-toggle');

function setPlayIcon(playing) {
  if (!playToggle) return;
  playToggle.textContent = playing ? DEFAULT_PAUSE_ICON : DEFAULT_PLAY_ICON;
  globalThis.MusicTreeUI?.setPlayIcon(playing);
  playToggle.setAttribute('aria-label', playing ? '暂停' : '播放');
}

$('#play-toggle').addEventListener('click', () => {
  const audio = $('#audio-player');
  if (audio.paused) { audio.play().catch(() => { setPlaybackStatus('播放失败 · 点击播放重试'); showToast('播放失败，请检查歌曲是否可用'); }); } else { audio.pause(); }
});

// Custom progress bar: click / drag to seek.
function fmtTime(seconds) {
  if (!Number.isFinite(seconds) || seconds < 0) return '0:00';
  const s = Math.floor(seconds);
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
}

function updateProgressUI() {
  const audio = $('#audio-player');
  const fill = $('#progress-fill');
  const thumb = $('#progress-thumb');
  const cur = $('#current-time');
  const dur = $('#duration-time');
  if (!fill) return;
  const duration = audio.duration || 0;
  const current = audio.currentTime || 0;
  const pct = duration > 0 ? (current / duration) : 0;
  fill.style.width = `${(pct * 100).toFixed(2)}%`;
  if (thumb) thumb.style.left = `${(pct * 100).toFixed(2)}%`;
  if (cur) cur.textContent = fmtTime(current);
  if (dur) dur.textContent = fmtTime(duration);
  $('#progress-track').setAttribute('aria-valuenow', String(Math.round(pct * 100)));
  $('#progress-track').setAttribute('aria-valuetext', `${fmtTime(current)} / ${fmtTime(duration)}`);
}

function seekToFraction(frac) {
  const audio = $('#audio-player');
  if (!audio.duration) return;
  const clamped = Math.max(0, Math.min(1, frac));
  audio.currentTime = clamped * audio.duration;
}

const progressTrack = $('#progress-track');
if (progressTrack) {
  let scrubbing = false;
  const fractionFromEvent = (event) => {
    const rect = progressTrack.getBoundingClientRect();
    if (rect.width <= 0) return 0;
    return (event.clientX - rect.left) / rect.width;
  };
  progressTrack.addEventListener('mousedown', (event) => {
    if (!event.currentTarget.classList.contains('progress-track')) return;
    scrubbing = true;
    seekToFraction(fractionFromEvent(event));
  });
  window.addEventListener('mousemove', (event) => { if (scrubbing) seekToFraction(fractionFromEvent(event)); });
  window.addEventListener('mouseup', () => { scrubbing = false; });
  progressTrack.addEventListener('click', (event) => {
    if (event.target.closest('#progress-thumb')) return;
    seekToFraction(fractionFromEvent(event));
  });
  progressTrack.addEventListener('keydown', (event) => {
    if (event.key === 'ArrowRight' || event.key === 'ArrowLeft') {
      event.preventDefault();
      const audio = $('#audio-player');
      const delta = event.key === 'ArrowRight' ? 5 : -5;
      audio.currentTime = Math.max(0, Math.min(audio.duration || 0, audio.currentTime + delta));
    }
  });
}

$('#audio-player').addEventListener('ended', nextItem);
$('#audio-player').addEventListener('seeking', () => {
  const session = state.playbackSession;
  const current = Number($('#audio-player').currentTime || 0);
  if (!session || session.key !== state.currentKey || (current <= 0.5 && session.playedSeconds === 0)) return;
  session.seeked = true;
  session.lastAudioTime = current;
});
$('#audio-player').addEventListener('timeupdate', () => {
  updateProgressUI();
  maybeRecordPlayback();
  if (!$('#lyrics-panel').hidden) renderLyrics($('#audio-player').currentTime);
});
$('#audio-player').addEventListener('loadedmetadata', updateProgressUI);
$('#audio-player').addEventListener('play', () => { setPlayIcon(true); setPlaybackStatus('正在播放'); render(); });
$('#audio-player').addEventListener('pause', () => { setPlayIcon(false); setPlaybackStatus('已暂停'); render(); });
$('#audio-player').addEventListener('waiting', () => setPlaybackStatus('正在缓冲…'));
$('#audio-player').addEventListener('playing', () => setPlaybackStatus('正在播放'));
$('#audio-player').addEventListener('error', () => { if (state.currentKey) setPlaybackStatus('播放失败 · 点击播放重试'); });

renderMode(); renderDisplayModeChoice(); loadRecommendations(); loadWanted(); loadProviderStatus();
// The display mode decides how the local names are rendered, so it is resolved
// before the local lists are fetched. An unreachable API keeps the traditional
// names rather than silently showing regularized ones.
loadDisplayModeSettings().finally(() => { loadLibrary(); loadListening(); });
setInterval(() => { if (document.hidden) return; loadLibrary(true); loadRecommendations(true); loadWanted(true); loadProviderStatus(); }, 15000);
document.addEventListener('visibilitychange', () => { if (!document.hidden) { loadLibrary(true); loadRecommendations(true); loadWanted(true); loadProviderStatus(); } });
$('#library-sort').value = state.librarySort;

// Restore listening sidebar collapse preference.
try {
  setListeningCollapsed(localStorage.getItem('musicserver-listening-collapsed') !== '0');
} catch {}

// Scroll forwarding: when the mouse wheel is on a non-scrollable area inside
// .recommendation-panel or .library-panel, forward the scroll to the panel's
// internal scrollable track-list.  This makes the hero card, stats row, and
// section headings scrollable without requiring the user to hover exactly on
// the thin track-list area.
function forwardScroll(event) {
  if (globalThis.MusicTreeUI) return;
  const panel = event.currentTarget;
  const scroller = panel.querySelector('.track-list');
  if (!scroller) return;
  // If the scroller itself can still scroll, let the browser handle it normally
  // (native overflow-y:auto already works when hovering directly on it).
  const maxScroll = scroller.scrollHeight - scroller.clientHeight;
  if (maxScroll <= 0) return;
  const atTop = scroller.scrollTop <= 0 && event.deltaY < 0;
  const atBottom = scroller.scrollTop >= maxScroll && event.deltaY > 0;
  if (!atTop && !atBottom) {
    scroller.scrollTop += event.deltaY;
    event.preventDefault();
  }
}

const recPanel = $('#recommendations');
if (recPanel) recPanel.addEventListener('wheel', forwardScroll, { passive: false });
const libPanel = $('#library');
if (libPanel) libPanel.addEventListener('wheel', forwardScroll, { passive: false });

// ======================== Settings Panel ========================

function setSettingsOpen(open, returnFocus = false) {
  $('#settings-panel').hidden = !open;
  $('#settings-toggle').setAttribute('aria-expanded', String(open));
  if (open) { loadMusicLibrarySettings(); loadDisplayModeSettings(); }
  if (returnFocus) $('#settings-toggle').focus();
}

// ======================== Display Mode ========================

// Traditional ('raw') shows the folder's own names; 'canonical' (Beta) shows the
// regularized song name and the resolved singer, album and year. The server owns
// the choice, and switching only re-renders: the library payload already carries
// both the raw and the resolved values.
function applyDisplayMode(mode) {
  const next = mode === 'canonical' ? 'canonical' : 'raw';
  if (state.displayMode === next) { renderDisplayModeChoice(); return; }
  state.displayMode = next;
  $('#library-list')._dirty = true;
  $('#recommendation-list')._dirty = true;
  renderDisplayModeChoice();
  if (state.currentItem) updatePlayer(state.currentItem);
  render();
}

function renderDisplayModeChoice() {
  document.querySelectorAll('input[name="display-mode"]').forEach((input) => {
    input.checked = input.value === state.displayMode;
  });
  const note = $('#display-mode-note');
  if (note) note.textContent = state.displayMode === 'canonical'
    ? '当前：正则模式（Beta）· 名称来自在线识别，可能与文件夹里的原始信息不同。'
    : '当前：传统模式 · 显示文件夹里的原始歌曲名和歌手。';
}

async function loadDisplayModeSettings() {
  try {
    const data = await fetchJson('/api/settings/display-mode');
    applyDisplayMode(data?.mode);
  } catch {
    // Keep the traditional default rather than guessing at a regularized name.
    renderDisplayModeChoice();
  }
}

async function saveDisplayMode(mode) {
  try {
    const result = await fetchJson('/api/settings/display-mode', {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ mode }),
    });
    applyDisplayMode(result?.mode || mode);
    showToast(mode === 'canonical' ? '已切换到正则模式（Beta）' : '已切换到传统模式');
  } catch (e) {
    showToast(`切换失败：${e.message}`);
    await loadDisplayModeSettings();
  }
}

document.querySelectorAll('input[name="display-mode"]').forEach((input) => {
  input.addEventListener('change', () => { if (input.checked) saveDisplayMode(input.value); });
});

async function loadMusicLibrarySettings() {
  try {
    const data = await fetchJson('/api/settings/music-library');
    $('#music-library-path').value = data.path || '';
    const status = $('#music-library-status');
    if (data.available) {
      status.className = 'settings-status ok';
      status.textContent = '目录可用';
    } else {
      status.className = 'settings-status unavailable';
      status.textContent = `音乐库当前不可用：${data.path}\n请连接磁盘或重新选择音乐库。`;
    }
    const sourceLabels = { environment: '环境变量指定', database: '自定义设置', default: '默认路径' };
    $('#music-library-source').textContent = `来源：${sourceLabels[data.source] || data.source}`;
  } catch (e) {
    showToast('无法加载音乐库设置');
  }
}

// Native folder picker via Tauri dialog plugin
$('#music-library-browse').addEventListener('click', async () => {
  try {
    // Tauri v2 IPC: invoke the pick_folder command registered in main.rs
    const invoke = window.__TAURI__?.core?.invoke;
    if (!invoke) {
      // Not running in Tauri WebView — fallback to prompt
      const path = prompt('输入音乐库完整路径（例如 D:\\Music）：', $('#music-library-path').value);
      if (path) await saveMusicLibraryPath(path);
      return;
    }
    const selected = await invoke('pick_folder');
    if (!selected) return; // user cancelled
    await saveMusicLibraryPath(selected);
  } catch (e) {
    showToast(`文件夹选择失败：${e}`);
  }
});

async function saveMusicLibraryPath(path) {
  try {
    const result = await fetchJson('/api/settings/music-library', {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ path }),
    });
    showToast(result.requires_restart ? '音乐库路径已更新，重启后生效' : '音乐库路径已更新');
    await loadMusicLibrarySettings();
  } catch (e) {
    showToast(`保存失败：${e.message}`);
  }
}

// Open folder in Explorer
$('#music-library-open').addEventListener('click', async () => {
  const path = $('#music-library-path').value;
  if (!path) return;
  try {
    const { invoke } = window.__TAURI__?.core || window.__TAURI__?.tauri || {};
    if (invoke) {
      await invoke('open_folder', { path });
    } else {
      // Fallback for non-Tauri environments
      showToast('打开文件夹仅在桌面 APP 中可用');
    }
  } catch (e) {
    showToast(`无法打开文件夹：${e.message}`);
  }
});

// Reset to default
$('#music-library-reset').addEventListener('click', async () => {
  if (!confirm('恢复默认音乐库位置？\n\n这不会移动或删除任何现有文件。')) return;
  try {
    const result = await fetchJson('/api/settings/music-library', { method: 'DELETE' });
    showToast(result.requires_restart ? '已恢复默认，重启后生效' : '已恢复默认');
    await loadMusicLibrarySettings();
  } catch (e) {
    showToast(`恢复失败：${e.message}`);
  }
});

// Toggle settings panel
$('#settings-toggle').addEventListener('click', () => {
  setSettingsOpen($('#settings-panel').hidden);
  if (!$('#settings-panel').hidden) $('#settings-close').focus();
});
$('#settings-close').addEventListener('click', () => setSettingsOpen(false, true));
