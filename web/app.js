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
  libraryOrder: storedLibraryOrder,
  currentKey: null,
  currentCollection: 'library',
  mode: localStorage.getItem('musicserver-play-mode') === 'random' && storedLibraryOrder.length ? 'random' : 'sequence',
  lyrics: { available: false, format: '', text: '', entries: [], quality: '', message: '' },
  lyricsRequest: 0,
};

const labels = { REMOTE: '在线', WANTED: '待下载', RESOLVING: '正在解析', DOWNLOADING: '下载中', VALIDATING: '校验中', CANCEL_REQUESTED: '正在取消', LOCAL: '已本地化', RETRY_WAIT: '等待重试', UNAVAILABLE: '暂不可用' };
const $ = (selector) => document.querySelector(selector);
const escapeHtml = (value) => String(value ?? '').replace(/[&<>'"]/g, (char) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;' }[char]));
const duration = (seconds) => { const value = Number(seconds || 0); return value ? `${Math.floor(value / 60)}:${String(Math.floor(value % 60)).padStart(2, '0')}` : '—'; };
const keyOf = (item) => String(item?.track_id || item?.id || '');
const itemStatus = (item) => item.wanted?.state || item.local_status || 'REMOTE';
const statusClass = (status) => status === 'LOCAL' ? 'local' : ['DOWNLOADING', 'RESOLVING', 'VALIDATING'].includes(status) ? 'downloading' : ['RETRY_WAIT', 'CANCEL_REQUESTED'].includes(status) ? 'retry' : '';
const normalizeLibraryItem = (item) => ({ ...item, title: item?.title || item?.name || '' });

function showToast(message) {
  const toast = $('#toast'); toast.textContent = message; toast.classList.add('show');
  clearTimeout(showToast.timer); showToast.timer = setTimeout(() => toast.classList.remove('show'), 2200);
}

function filteredLibrary() {
  const query = ($('#library-search')?.value || '').trim().toLocaleLowerCase();
  if (!query) return state.library;
  return state.library.filter((item) => [item.title, item.artist, item.album].some((value) => String(value || '').toLocaleLowerCase().includes(query)));
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
  const visible = filteredLibrary();
  $('#library-count').textContent = `${state.library.length} 首`;
  $('#library-nav-count').textContent = state.library.length;
  $('#local-count').textContent = state.library.length;
  if (!state.library.length) { list.innerHTML = '<div class="empty-state">本地曲库还没有歌曲。</div>'; return; }
  if (!visible.length) { list.innerHTML = '<div class="empty-state">没有找到匹配的歌曲。</div>'; return; }
  list.innerHTML = visible.map((item) => {
    const playing = state.currentKey === keyOf(item);
    const meta = [item.artist || '未知艺术家', item.album || '未知专辑'].filter(Boolean).join(' · ');
    return `<article class="track-row library-row ${playing ? 'playing' : ''}" data-library-id="${escapeHtml(item.id)}">
      <button class="play-button" data-action="play" aria-label="播放 ${escapeHtml(item.title)}">${playing && !$('#audio-player').paused ? '❚❚' : '▶'}</button>
      <div class="track-main"><div class="track-title">${escapeHtml(item.title || '未命名歌曲')}</div><div class="track-artist">${escapeHtml(meta)}</div></div>
      <span class="library-mark">${item.starred ? '♥' : (item.source === 'DailyMix' ? '今日' : '')}</span>
      <span class="track-duration">${duration(item.duration)}</span>
      <button class="lyrics-button" data-action="lyrics" aria-label="查看歌词">词</button>
    </article>`;
  }).join('');
}

function renderRecommendations() {
  const list = $('#recommendation-list');
  $('#recommendation-count').textContent = state.items.length;
  $('#hero-count').textContent = state.items.length || 20;
  $('#liked-count').textContent = state.items.filter((item) => item.liked).length;
  $('#local-count').textContent = state.library.length;
  $('#wanted-count').textContent = state.items.filter((item) => item.wanted?.state && item.wanted.state !== 'LOCAL').length;
  $('#queue-count').textContent = state.items.filter((item) => item.wanted?.state && item.wanted.state !== 'LOCAL').length;
  if (!state.items.length) { list.innerHTML = '<div class="empty-state">今天还没有推荐，稍后再来看看。</div>'; return; }
  list.innerHTML = state.items.map((item) => {
    const status = itemStatus(item); const playing = state.currentKey === keyOf(item);
    return `<article class="track-row ${playing ? 'playing' : ''}" data-track-id="${escapeHtml(item.track_id)}">
      <button class="play-button" data-action="play" aria-label="播放 ${escapeHtml(item.title)}">${playing && !$('#audio-player').paused ? '❚❚' : '▶'}</button>
      <div class="track-main"><div class="track-title">${escapeHtml(item.title)}</div><div class="track-artist">${escapeHtml(item.artist || '未知艺术家')}</div><div class="track-reason">${escapeHtml(item.reason || '为你推荐')}</div></div>
      <span class="status-badge ${statusClass(status)}">${escapeHtml(labels[status] || status)}</span>
      <span class="track-duration">${duration(item.duration)}</span>
      <button class="heart-button ${item.liked ? 'liked' : ''}" data-action="like" aria-label="${item.liked ? '取消喜欢' : '喜欢'}" aria-pressed="${item.liked}">${item.liked ? '♥' : '♡'}</button>
    </article>`;
  }).join('');
  $('#play-first').disabled = !state.items[0];
}

function playbackCollection() { return state.currentCollection === 'recommendations' ? state.items : filteredLibrary(); }

function updateNavigationButtons() {
  const collection = playbackCollection();
  const disabled = !collection.length || !state.currentKey;
  $('#previous-button').disabled = disabled;
  $('#next-button').disabled = disabled;
}

function render() { renderLibrary(); renderRecommendations(); renderMode(); updateNavigationButtons(); }

function renderMode() {
  document.querySelectorAll('.mode-button').forEach((button) => button.classList.toggle('active', button.dataset.mode === state.mode));
  $('#shuffle-button').classList.toggle('active', state.mode === 'random');
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
  content.innerHTML = state.lyrics.entries.map((entry, index) => `<div class="lyric-line ${index === active ? 'active' : ''}">${escapeHtml(entry.text)}</div>`).join('');
  const activeLine = content.querySelector('.lyric-line.active');
  if (activeLine) activeLine.scrollIntoView({ block: 'center', behavior: 'smooth' });
}

async function loadLyrics(url, open = true) {
  const requestId = ++state.lyricsRequest;
  state.lyrics = { available: false, format: '', text: '', entries: [], quality: '', message: '' };
  $('#lyrics-toggle').disabled = false;
  if (open) $('#lyrics-panel').hidden = false;
  $('#lyrics-content').innerHTML = '<div class="lyrics-empty">正在加载歌词…</div>';
  if (!url) { renderLyrics(); return; }
  try {
    const response = await fetch(url, { cache: 'no-store' });
    const data = await response.json();
    if (requestId !== state.lyricsRequest) return;
    if (!response.ok && !data?.available) {
      state.lyrics = normalizeLyricsPayload(data);
      renderLyrics();
      return;
    }
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
    const response = await fetch(`/api/tracks/${encodeURIComponent(item.track_id)}`, { cache: 'no-store' });
    if (!response.ok) return item;
    const details = await response.json();
    if (details.track) item.track = details.track;
    if (details.recommendation) item.recommendation = details.recommendation;
    if (details.playback_source) item.playback_source = details.playback_source;
    if (details.local_status) item.local_status = details.local_status;
    if (details.playback_source?.type === 'local' && details.playback_source?.url) item.stream_url = details.playback_source.url;
  } catch {}
  return item;
}

async function playItem(item, collection = 'library') {
  const key = keyOf(item); const audio = $('#audio-player');
  if (!key) return;
  if (state.currentKey === key && !audio.paused) { audio.pause(); return; }
  let source = resolvePlaybackSource(item);
  if (!source && item.track_id) {
    await hydrateRecommendationPlayback(item);
    source = resolvePlaybackSource(item);
  }
  if (!source) { showToast('这首歌暂时没有可用试听源'); return; }
  const sourceUrl = new URL(source, window.location.href).href;
  const isNewTrack = state.currentKey !== key || audio.src !== sourceUrl;
  state.currentKey = key; state.currentCollection = collection; updatePlayer(item); render();
  if (isNewTrack) { audio.pause(); audio.currentTime = 0; audio.src = sourceUrl; }
  const lyricsUrl = collection === 'recommendations' && item.track_id
    ? `/api/tracks/${encodeURIComponent(item.track_id)}/lyrics`
    : item.lyrics_url || (item.track_id ? `/api/tracks/${encodeURIComponent(item.track_id)}/lyrics` : '');
  await loadLyrics(lyricsUrl, true);
  try { await audio.play(); } catch { showToast('试听源加载失败，请稍后重试'); }
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
  const next = !item.liked; item.liked = next; render(); showToast(next ? '已喜欢，加入后台下载队列' : '已取消喜欢');
  try {
    const response = await fetch(`/api/tracks/${encodeURIComponent(item.track_id)}/like`, { method: next ? 'POST' : 'DELETE' });
    if (!response.ok) throw new Error('like request failed');
    const result = await response.json(); item.wanted = result.wanted; render();
  } catch { item.liked = !next; render(); showToast('操作失败，请稍后重试'); }
}

async function loadLibrary(silent = false) {
  try {
    const response = await fetch('/api/library', { cache: 'no-store' });
    if (!response.ok) throw new Error('library request failed');
    const payload = await response.json(); syncLibrary(payload.items || []); renderLibrary(); updateNavigationButtons();
  } catch { if (!silent) { $('#library-list').innerHTML = '<div class="empty-state">暂时无法读取 Navidrome 音乐库。</div>'; showToast('音乐库同步失败'); } }
}

async function loadRecommendations(silent = false) {
  try {
    const response = await fetch('/api/recommendations/today', { cache: 'no-store' });
    if (!response.ok) throw new Error('recommendation request failed');
    const payload = await response.json(); state.items = payload.items || [];
    $('#last-updated').textContent = `更新于 ${new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}`;
    $('#error-banner').hidden = true; renderRecommendations(); updateNavigationButtons();
    if (!silent && state.items.length) $('#play-first').disabled = false;
  } catch { $('#error-banner').textContent = '暂时无法连接 MusicServer API，请确认 music_api.ps1 正在运行。'; $('#error-banner').hidden = false; if (!silent) renderRecommendations(); }
}

async function loadProviderStatus() {
  try {
    const response = await fetch('/api/providers/status', { cache: 'no-store' }); const data = await response.json();
    const blocked = (data.items || []).filter((item) => String(item.provider || '').startsWith('bilibili_') && item.state === 'OPEN');
    if (blocked.length) {
      const names = blocked.map((item) => item.provider === 'bilibili_search' ? '搜索' : '下载').join(' / ');
      $('#provider-summary').textContent = `Bilibili ${names}冷却中 · 不影响试听`;
    } else {
      $('#provider-summary').textContent = '本地优先 · Provider 正常';
    }
  } catch { $('#provider-summary').textContent = 'Provider 状态暂不可用'; }
}

$('#library-list').addEventListener('click', (event) => {
  const row = event.target.closest('[data-library-id]'); if (!row) return;
  const item = state.library.find((candidate) => candidate.id === row.dataset.libraryId); if (!item) return;
  if (event.target.closest('[data-action="lyrics"]')) loadLyrics(item.lyrics_url, true);
  else if (event.target.closest('[data-action="play"]')) playItem(item, 'library');
});

$('#recommendation-list').addEventListener('click', (event) => {
  const row = event.target.closest('[data-track-id]'); if (!row) return;
  const item = state.items.find((candidate) => candidate.track_id === row.dataset.trackId); if (!item) return;
  if (event.target.closest('[data-action="like"]')) toggleLike(item);
  else if (event.target.closest('[data-action="play"]')) playItem(item, 'recommendations');
});

$('#library-search').addEventListener('input', () => { renderLibrary(); updateNavigationButtons(); });
document.querySelectorAll('.mode-button').forEach((button) => button.addEventListener('click', () => {
  setPlaybackMode(button.dataset.mode);
}));
$('#shuffle-button').addEventListener('click', reshuffleLibrary);
$('#refresh-button').addEventListener('click', () => { loadLibrary(); loadRecommendations(); loadProviderStatus(); });
$('#play-first').addEventListener('click', () => state.items[0] && playItem(state.items[0], 'recommendations'));
$('#previous-button').addEventListener('click', previousItem);
$('#next-button').addEventListener('click', nextItem);
$('#lyrics-toggle').addEventListener('click', () => { $('#lyrics-panel').hidden = !$('#lyrics-panel').hidden; });
$('#lyrics-close').addEventListener('click', () => { $('#lyrics-panel').hidden = true; });
$('#audio-player').addEventListener('ended', nextItem);
$('#audio-player').addEventListener('timeupdate', () => { if (!$('#lyrics-panel').hidden) renderLyrics($('#audio-player').currentTime); });
$('#audio-player').addEventListener('play', render);
$('#audio-player').addEventListener('pause', render);

renderMode(); loadLibrary(); loadRecommendations(); loadProviderStatus();
setInterval(() => { loadLibrary(true); loadRecommendations(true); loadProviderStatus(); }, 15000);