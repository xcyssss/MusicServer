// Tauri startup uses this marker to reject a stale 8790 UI process after an
// upgrade. Keep it in the served bundle so the desktop shell can verify that
// the WebView is loading the same source revision as the backend.
const MUSICSERVER_BUILD_MARKER = 'musicserver-single-page-v3';

const storedLibraryOrder = (() => {
  try {
    const value = JSON.parse(localStorage.getItem('musicserver-library-order') || '[]');
    return Array.isArray(value) ? value.map(String) : [];
  } catch { return []; }
})();

const state = {
  items: [],
  library: [],
  librarySequence: [],
  listening: { mostPlayed: [], rediscover: [], loaded: false },
  libraryOrder: storedLibraryOrder,
  currentKey: null,
  currentCollection: 'library',
  playbackSession: null,
  lastRandomId: null,
  mode: localStorage.getItem('musicserver-play-mode') === 'random' && storedLibraryOrder.length ? 'random' : 'sequence',
  librarySort: localStorage.getItem('musicserver-library-sort') || 'default',
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

const PLAYBACK_MIN_SECONDS = 30;
const PLAYBACK_MIN_RATIO = 0.25;

const refreshes = new Map();
const pendingLikes = new Set();
async function fetchJson(url, options = {}) {
  const controller = new AbortController();
  const cancel = () => controller.abort();
  if (options.signal?.aborted) cancel();
  options.signal?.addEventListener('abort', cancel, { once: true });
  const timer = setTimeout(cancel, 12000);
  try {
    const response = await fetch(url, { ...options, cache: 'no-store', signal: controller.signal });
    const payload = await response.json();
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
  if (!query) return state.library;
  return state.library.filter((item) => item.searchText.includes(query));
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
  incoming.forEach((item) => { item.searchText = [item.title, item.artist, item.album].map((value) => String(value || '').toLocaleLowerCase()).join('\n'); });
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
  if (!state.library.length) { list._sig = null; list.innerHTML = '<div class="empty-state">曲库还是空的。<br />从右侧推荐开始，点红心收藏喜欢的音乐。</div>'; return; }
  if (!visible.length) { list._sig = null; list.innerHTML = '<div class="empty-state">没有找到匹配的歌曲。<br />试试歌手名，或清空搜索。</div>'; return; }
  const signature = JSON.stringify(visible.map((item) => [keyOf(item), state.currentKey === keyOf(item), $('#audio-player').paused, item.starred, item.source, item.title, item.artist, item.album, item.duration]));
  if (list._sig === signature && !list._dirty) return;
  list._sig = signature;
  list._dirty = false;
  replaceList(list, visible.map((item) => {
    const playing = state.currentKey === keyOf(item);
    const meta = [item.artist || '未知艺术家', item.album || '未知专辑'].filter(Boolean).join(' · ');
    return `<article class="track-row library-row ${playing ? 'playing' : ''}" data-library-id="${escapeHtml(item.id)}">
      <button class="play-button" data-action="play" aria-label="${playing && !$('#audio-player').paused ? '暂停' : '播放'} ${escapeHtml(item.title)}">${playing && !$('#audio-player').paused ? '❚❚' : '▶'}</button>
      <div class="track-main"><div class="track-title">${escapeHtml(item.title || '未命名歌曲')}</div><div class="track-artist">${escapeHtml(meta)}</div></div>
      <span class="library-mark">${item.starred ? '♥' : (item.source === 'DailyMix' ? '今日' : '')}</span>
      <span class="track-duration">${duration(item.duration)}</span>
      <button class="lyrics-button" data-action="lyrics" aria-label="查看歌词">词</button>
      <button class="delete-button" data-action="delete" aria-label="删除这首歌" title="删除">✕</button>
    </article>`;
  }).join(''));
}

function renderRecommendations() {
  const list = $('#recommendation-list');
  $('#recommendation-count').textContent = state.items.length;
  $('#hero-count').textContent = state.items.length;
  $('#play-first').disabled = !state.items.length;
  $('#liked-count').textContent = state.items.filter((item) => item.liked).length;
  $('#local-count').textContent = state.library.length;
  $('#wanted-count').textContent = state.items.filter((item) => item.wanted?.state && item.wanted.state !== 'LOCAL').length;
  $('#queue-count').textContent = state.items.filter((item) => item.wanted?.state && item.wanted.state !== 'LOCAL').length;
  const wanted = state.items.filter((item) => item.wanted?.state && item.wanted.state !== 'LOCAL');
  $('#wanted-list').innerHTML = wanted.length ? wanted.map((item) => `<div class="wanted-row"><span>${escapeHtml(item.title)}</span><span class="status-badge ${statusClass(itemStatus(item))}">${escapeHtml(labels[itemStatus(item)] || itemStatus(item))}</span></div>`).join('') : '当前推荐没有待下载歌曲。';
  if (!state.items.length) { list._sig = null; list.innerHTML = '<div class="empty-state">今天的推荐还在准备中。<br />先从音乐库选一首，或稍后刷新。</div>'; return; }
  const signature = JSON.stringify(state.items.map((item) => [item.track_id, item.liked, itemStatus(item), state.currentKey === keyOf(item), $('#audio-player').paused, item.title, item.artist, item.reason, item.duration, pendingLikes.has(item.track_id)]));
  if (list._sig === signature && !list._dirty) return;
  list._sig = signature;
  list._dirty = false;
  replaceList(list, state.items.map((item) => {
    const status = itemStatus(item); const playing = state.currentKey === keyOf(item);
    return `<article class="track-row ${playing ? 'playing' : ''}" data-track-id="${escapeHtml(item.track_id)}">
      <button class="play-button" data-action="play" aria-label="${playing && !$('#audio-player').paused ? '暂停' : '播放'} ${escapeHtml(item.title)}">${playing && !$('#audio-player').paused ? '❚❚' : '▶'}</button>
      <div class="track-main"><div class="track-title">${escapeHtml(item.title)}</div><div class="track-artist">${escapeHtml(item.artist || '未知艺术家')}</div><div class="track-reason">${escapeHtml(item.reason || '为你推荐')}</div></div>
      <span class="status-badge ${statusClass(status)}">${escapeHtml(labels[status] || status)}</span>
      <span class="track-duration">${duration(item.duration)}</span>
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
    ? most.map((item, index) => `<article class="listening-row" data-listening-id="${escapeHtml(item.id || item.library_id || item.identity)}">
        <span class="listening-rank">${String(index + 1).padStart(2, '0')}</span>
        <button class="listening-play" data-action="play" type="button" aria-label="播放 ${escapeHtml(item.title)}">▶</button>
        <div class="listening-main"><div class="listening-title">${escapeHtml(item.title || '未命名歌曲')}</div><div class="listening-artist">${escapeHtml(item.artist || '未知艺术家')}</div></div>
        <span class="listening-count">${Number(item.play_count || 0)} 次</span>
      </article>`).join('')
    : '<div class="listening-empty">播放满 30 秒后，这里会留下你的常听。</div>';

  rediscoverList.innerHTML = rediscover.length
    ? rediscover.map((item) => `<article class="listening-row rediscover-row" data-listening-id="${escapeHtml(item.id || item.library_id || item.identity)}">
        <span class="rediscover-mark">✦</span>
        <button class="listening-play" data-action="play" type="button" aria-label="播放 ${escapeHtml(item.title)}">▶</button>
        <div class="listening-main"><div class="listening-title">${escapeHtml(item.title || '未命名歌曲')}</div><div class="listening-artist">${escapeHtml(item.artist || '未知艺术家')}</div></div>
        <span class="listening-count">${Number(item.play_count || 0) ? `${Number(item.play_count)} 次` : '未播放'}</span>
      </article>`).join('')
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
  $('#player-title').textContent = item.title || '未命名歌曲';
  $('#player-artist').textContent = item.artist || '未知艺术家';
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
  state.currentKey = key; state.currentCollection = collection; updatePlayer(item); $('#library-list')._dirty = true; $('#recommendation-list')._dirty = true; render();
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
    item.wanted = result?.wanted || null;
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
    const payload = await fetchJson('/api/library');
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
  try { await Promise.all([loadLibrary(), loadRecommendations(), loadListening(), loadProviderStatus()]); }
  finally { $('#refresh-button').disabled = false; $('#refresh-button').setAttribute('aria-busy', 'false'); }
});
$('#rediscover-button').addEventListener('click', () => loadListening());
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
    if (!$('#lyrics-panel').hidden) setLyricsOpen(false, true);
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

renderMode(); loadLibrary(); loadRecommendations(); loadListening(); loadProviderStatus();
setInterval(() => { if (document.hidden) return; loadLibrary(true); loadRecommendations(true); loadProviderStatus(); }, 15000);
document.addEventListener('visibilitychange', () => { if (!document.hidden) { loadLibrary(true); loadRecommendations(true); loadProviderStatus(); } });
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
