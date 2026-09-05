const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../web/app.js'), 'utf8');
const markup = fs.readFileSync(path.join(__dirname, '../web/index.html'), 'utf8');
const settle = () => new Promise(resolve => setImmediate(resolve));
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };

// Execute the shipped script, including its event wiring. A small DOM double
// lets CI exercise timing/state contracts without a browser or live music DB.
// Real layout and media acceptance are separately performed in the Tauri APP.
async function app() {
  const elements = new Map();
  const events = new Map();
  const intervals = [];
  const timers = new Map();
  const requests = [];
  const document = { hidden: false, activeElement: null, querySelector: s => elements.get(s), querySelectorAll: () => [], addEventListener: (name, fn) => events.set(name, fn) };
  function element(id, tag) {
    const attrs = new Map();
    const classes = new Set((/class="([^"]*)"/.exec(tag)?.[1] || '').split(' '));
    const listeners = new Map();
    let html = '';
    return { id, value: '', hidden: /\shidden(?:\s|>)/.test(tag), disabled: /\sdisabled(?:\s|>)/.test(tag), style: {}, dataset: {}, scrollTop: 0, writes: 0,
      get innerHTML() { return html; }, set innerHTML(v) { html = v; this.writes++; },
      classList: { contains: c => classes.has(c), add: c => classes.add(c), remove: c => classes.delete(c), toggle(c, force) { const next = force ?? !classes.has(c); if (next) classes.add(c); else classes.delete(c); } },
      setAttribute: (k, v) => attrs.set(k, v), getAttribute: k => attrs.get(k), hasAttribute: k => attrs.has(k), removeAttribute: k => attrs.delete(k),
      addEventListener(name, fn) { if (!listeners.has(name)) listeners.set(name, []); listeners.get(name).push(fn); },
      emit(name, event = {}) { return Promise.all((listeners.get(name) || []).map(fn => fn({ target: this, ...event }))); },
      querySelector: () => null, querySelectorAll: () => [], contains: () => false, focus() { document.activeElement = this; },
    };
  }
  for (const match of markup.matchAll(/<[^>]+\bid="([^"]+)"[^>]*>/g)) elements.set('#' + match[1], element(match[1], match[0]));
  elements.set('.app-shell', element('shell', ''));
  const audio = elements.get('#audio-player');
  Object.assign(audio, { paused: true, currentTime: 0, duration: 120, src: '', playCalls: 0, pause() { this.paused = true; void this.emit('pause'); }, async play() { this.paused = false; this.playCalls++; await this.emit('play'); }, load() {} });
  const context = vm.createContext({ document, window: { location: { href: 'http://127.0.0.1:8790/' }, addEventListener() {}, confirm: () => true },
    localStorage: { getItem: () => null, setItem() {}, removeItem() {} }, console, URL, AbortController, CSS: { escape: s => s },
    setTimeout(fn, delay) { const timer = setTimeout(fn, delay); timer.unref(); timers.set(timer, { fn, delay }); return timer; },
    clearTimeout(timer) { clearTimeout(timer); timers.delete(timer); }, setInterval(fn) { intervals.push(fn); },
    fetch: async (url, options = {}) => {
      requests.push({ url, options });
      if (context.fetchHandler) return context.fetchHandler(url, options);
      return { ok: true, json: async () => ({ items: [], most_played: [], rediscover: [] }) };
    },
  });
  vm.runInContext(source, context);
  await settle();
  requests.length = 0;
  return { context, get: id => elements.get('#' + id), run: code => vm.runInContext(code, context), requests, intervals, events, timers };
}
const json = payload => ({ ok: true, json: async () => payload });
const library = [{ id: 'library-a', title: '春天', artist: '测试歌手', album: '专辑', duration: 120, stream_url: '/api/library/library-a/stream', local_status: 'LOCAL' }];

test('metadata and pause changes render; unchanged data keeps the list; clearing search restores rows', async () => {
  const a = await app(); a.context.tracks = library;
  a.run('syncLibrary(tracks); renderLibrary();');
  const list = a.get('library-list'); const writes = list.writes;
  a.run('renderLibrary()'); assert.equal(list.writes, writes);
  a.run("state.currentKey = 'library-a'; renderLibrary()");
  a.get('audio-player').paused = false; a.run('renderLibrary()'); assert.match(list.innerHTML, /暂停 春天/);
  a.get('audio-player').paused = true; a.run('renderLibrary()'); assert.match(list.innerHTML, /播放 春天/);
  a.run("state.library[0].title = '新的歌名'; renderLibrary()"); assert.match(list.innerHTML, /新的歌名/);
  a.run("state.searchQuery = 'not-found'; renderLibrary(); state.searchQuery = ''; renderLibrary();"); assert.match(list.innerHTML, /新的歌名/);
});

test('10,000 tracks have bounded initial DOM, load more, and composition-aware search', async () => {
  const a = await app(); a.context.tracks = Array.from({ length: 10000 }, (_, i) => ({ ...library[0], id: 'library-' + i, title: i === 9999 ? '中文独特歌曲' : 'Track ' + i }));
  a.run('syncLibrary(tracks); renderLibrary();');
  assert.equal((a.get('library-list').innerHTML.match(/<article/g) || []).length, 200);
  await a.get('library-more').emit('click'); assert.equal((a.get('library-list').innerHTML.match(/<article/g) || []).length, 400);
  const search = a.get('library-search'); const writes = a.get('library-list').writes;
  await search.emit('compositionstart'); search.value = '中文'; await search.emit('input');
  await new Promise(resolve => setTimeout(resolve, 180)); assert.equal(a.get('library-list').writes, writes);
  await search.emit('compositionend'); await new Promise(resolve => setTimeout(resolve, 180));
  assert.match(a.get('library-list').innerHTML, /中文独特歌曲/); assert.equal(a.get('library-more').hidden, true);
});

test('refreshes coalesce and an old library response cannot undo a mutation', async () => {
  const a = await app(); const response = deferred();
  a.context.fetchHandler = () => response.promise;
  const first = a.run('loadLibrary(true)'); const second = a.run('loadLibrary(true)'); await settle();
  assert.equal(a.requests.length, 1); a.run('state.libraryRevision++');
  response.resolve(json({ items: library })); await Promise.all([first, second]);
  assert.equal(a.run('state.library.length'), 0);
});

test('like writes serialize per track and stale recommendations cannot undo the result', async () => {
  const a = await app(); const reading = deferred(); const writing = deferred();
  a.context.track = { track_id: 'one', title: 'One', liked: false };
  a.run('state.items = [track]');
  a.context.fetchHandler = url => url.endsWith('/like') ? writing.promise : reading.promise;
  const refresh = a.run('loadRecommendations(true)'); await settle();
  const like = a.run('toggleLike(track)'); await a.run('toggleLike(track)');
  reading.resolve(json({ items: [{ track_id: 'one', title: 'Old', liked: false }] })); await refresh;
  assert.equal(a.run('state.items[0].liked'), true);
  assert.equal(a.requests.filter(r => r.url.endsWith('/like')).length, 1);
  writing.resolve(json({ liked: true, wanted: { state: 'WANTED' } })); await like;
  assert.match(a.get('wanted-list').innerHTML, /One/);
});

test('switching tracks ignores slow hydration and audio does not wait for lyrics', async () => {
  const a = await app(); const hydration = deferred(); const lyrics = deferred();
  a.context.fetchHandler = url => url === '/api/tracks/slow' ? hydration.promise : lyrics.promise;
  a.context.fastTrack = { ...library[0], lyrics_url: '/lyrics' };
  const slow = a.run("playItem({ track_id: 'slow', title: 'Slow' }, 'recommendations')");
  await a.run('playItem(fastTrack)');
  assert.equal(a.get('audio-player').playCalls, 1); assert.equal(a.get('lyrics-panel').hidden, true);
  hydration.resolve(json({ playback_source: { type: 'local', url: '/old.mp3' } })); await slow;
  assert.equal(a.run('state.currentKey'), 'library-a'); assert.match(a.get('audio-player').src, /library-a/);
  lyrics.resolve(json({ available: false })); await settle();
});

test('obsolete lyrics requests are aborted and cannot replace newer lyrics', async () => {
  const a = await app(); const older = deferred();
  a.context.fetchHandler = url => url === '/old' ? older.promise : Promise.resolve(json({ available: true, text: 'New lyrics', format: 'plain' }));
  const old = a.run("loadLyrics('/old', false)"); await a.run("loadLyrics('/new', false)");
  assert.equal(a.requests[0].options.signal.aborted, true);
  older.resolve(json({ available: true, text: 'Old lyrics' })); await old;
  assert.match(a.get('lyrics-content').innerHTML, /New lyrics/); assert.doesNotMatch(a.get('lyrics-content').innerHTML, /Old lyrics/);
});

test('hidden windows skip data polling and resume without polling listening statistics', async () => {
  const a = await app(); a.context.document.hidden = true; a.intervals[0](); await settle(); assert.equal(a.requests.length, 0);
  a.context.document.hidden = false; a.events.get('visibilitychange')(); await settle();
  assert.equal(a.requests.length, 3); assert.equal(a.requests.some(r => r.url.includes('/listening/')), false);
});

test('JSON deadline aborts a stalled response body', async () => {
  const a = await app();
  a.context.fetchHandler = (url, options) => Promise.resolve({ ok: true, json: () => new Promise((resolve, reject) => options.signal.addEventListener('abort', () => reject(new Error('aborted')), { once: true })) });
  const pending = a.run("fetchJson('/stalled')"); await settle();
  const assertion = assert.rejects(pending, /aborted/);
  for (const timer of a.timers.values()) if (timer.delay === 12000) timer.fn();
  await assertion;
});
