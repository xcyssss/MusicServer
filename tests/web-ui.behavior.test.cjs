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

test('explicit library refresh bypasses the derived cache while background polling reuses it', async () => {
  const a = await app();
  await a.run('loadLibrary()');
  await a.run('loadLibrary(true)');
  assert.equal(a.requests[0].url, '/api/library?refresh=1');
  assert.equal(a.requests[1].url, '/api/library');
});

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

test('dislike writes serialize per track and liking clears the dislike', async () => {
  const a = await app(); const writing = deferred();
  a.context.track = { track_id: 'one', title: 'One', liked: false, disliked: false };
  a.run('state.items = [track]');
  a.context.fetchHandler = url => url.endsWith('/dislike') ? writing.promise : json({});
  const dislike = a.run('toggleDislike(track)'); await a.run('toggleDislike(track)');
  // The optimistic state renders immediately and a second click must not fire a
  // second write while the first is still in flight.
  assert.equal(a.run('state.items[0].disliked'), true);
  assert.equal(a.requests.filter(r => r.url.endsWith('/dislike')).length, 1);
  assert.match(a.get('recommendation-list').innerHTML, /dislike-button disliked/);
  writing.resolve(json({ disliked: true })); await dislike;
  assert.equal(a.run('state.items[0].disliked'), true);

  // Liking is the same axis, so the server-reported like must clear the dislike.
  a.context.likeTrack = { track_id: 'one', title: 'One', liked: false, disliked: true };
  a.run('state.items = [likeTrack]');
  a.context.fetchHandler = url => url.endsWith('/like') ? json({ liked: true, wanted: null }) : json({});
  await a.run('toggleLike(likeTrack)');
  assert.equal(a.run('state.items[0].liked'), true);
  assert.equal(a.run('state.items[0].disliked'), false);
});

test('a failed dislike reverts the button', async () => {
  const a = await app();
  a.context.track = { track_id: 'one', title: 'One', liked: false, disliked: false };
  a.run('state.items = [track]');
  a.context.fetchHandler = () => ({ ok: false, status: 500, statusText: 'ERR', json: async () => ({ error: 'BOOM' }) });
  await a.run('toggleDislike(track)');
  assert.equal(a.run('state.items[0].disliked'), false);
  assert.doesNotMatch(a.get('recommendation-list').innerHTML, /dislike-button disliked/);
});

test('the release year is shown only when it is actually known', async () => {
  const a = await app();
  a.run("state.displayMode = 'canonical'; state.items = [{ track_id: 'a', title: 'Old Song', artist: '许嵩', year: 2009 }, { track_id: 'b', title: 'No Year', artist: '歌手', year: 0 }]; renderRecommendations();");
  const html = a.get('recommendation-list').innerHTML;
  assert.match(html, /2009 年/);
  // 0 means unknown, so no year may be invented for the second row.
  assert.doesNotMatch(html, /0 年/);
  assert.match(html, /library|No Year/);
});

test('the library renders a resolved release year', async () => {
  const a = await app();
  a.context.fetchHandler = url => url.includes('/api/library') ? json({ items: [{ ...library[0], year: 1999 }] }) : json({});
  await a.run("state.displayMode = 'canonical'; loadLibrary(true)");
  assert.match(a.get('library-list').innerHTML, /1999 年/);
});

test('a queued download stays visible after the daily list no longer contains it', async () => {
  const a = await app();
  a.run("state.items = []; state.wanted = [{ track_id: 'zeal', state: 'RETRY_WAIT', attempt_count: 4, max_attempts: 5, title: 'ZEAL of proud', artist: 'Roselia' }]; renderRecommendations();");
  assert.match(a.get('wanted-list').innerHTML, /ZEAL of proud/);
  assert.match(a.get('wanted-list').innerHTML, /等待重试/);
  assert.equal(a.get('queue-count').textContent, 1);
  assert.equal(a.get('wanted-count').textContent, 1);

  a.run("state.wanted = []; state.items = [{ track_id: 'zeal', title: 'ZEAL of proud', liked: false }]; renderRecommendations();");
  assert.doesNotMatch(a.get('wanted-list').innerHTML, /ZEAL of proud/);
  assert.equal(a.get('queue-count').textContent, 0);
});

test('a failed queue entry offers a retry that reposts it to the queue', async () => {
  const a = await app();
  a.run("state.items = []; state.wanted = [{ track_id: 'zeal', state: 'UNAVAILABLE', title: 'ZEAL of proud', artist: 'Roselia' }]; renderRecommendations();");
  assert.match(a.get('wanted-list').innerHTML, /data-action="wanted-retry"/);
  assert.match(a.get('wanted-list').innerHTML, /暂不可用/);

  a.run("state.wanted = [{ track_id: 'zeal', state: 'DOWNLOADING', title: 'ZEAL of proud', artist: 'Roselia' }]; renderRecommendations();");
  assert.doesNotMatch(a.get('wanted-list').innerHTML, /data-action="wanted-retry"/);

  a.run("state.wanted = [{ track_id: 'zeal', state: 'UNAVAILABLE', title: 'ZEAL of proud', artist: 'Roselia' }]; renderRecommendations();");
  const button = { disabled: false, getAttribute: name => (name === 'data-action' ? 'wanted-retry' : 'zeal') };
  await a.get('wanted-list').emit('click', { target: button });
  const retry = a.requests.find(r => r.url === '/api/wanted/zeal/retry');
  assert.ok(retry, 'retry request was issued');
  assert.equal(retry.options.method, 'POST');
  assert.ok(a.requests.some(r => r.url === '/api/wanted'), 'queue refreshed after retry');
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
  assert.equal(a.requests.length, 4); assert.equal(a.requests.some(r => r.url.includes('/listening/')), false);
  assert.equal(a.requests.some(r => r.url === '/api/wanted'), true);
});

test('JSON deadline aborts a stalled response body', async () => {
  const a = await app();
  a.context.fetchHandler = (url, options) => Promise.resolve({ ok: true, json: () => new Promise((resolve, reject) => options.signal.addEventListener('abort', () => reject(new Error('aborted')), { once: true })) });
  const pending = a.run("fetchJson('/stalled')"); await settle();
  const assertion = assert.rejects(pending, /aborted/);
  for (const timer of a.timers.values()) if (timer.delay === 12000) timer.fn();
  await assertion;
});

// Song titles in this library are raw 视频 filenames, so the display formatter
// has to find the song without inventing or truncating one. These cases are the
// real filenames that the previous "first bracket wins" rule got wrong.
const titleCases = [
  ['「猫头鹰之城」Fireflies 萤火虫 - Owl City 百万级装备试听【Hi-Res】', 'Fireflies 萤火虫'],
  ['【中字4K·HiRes】「壱雫空」- MyGO!!!!!｜Divide⧸Unite p01 「壱雫空」', '壱雫空'],
  ['【附歌词中字】Roselia「Fear Nothing」【FULL】', 'Fear Nothing'],
  ['【附歌词中字】Roselia -「Dazzle the Destiny」【FULL】', 'Dazzle the Destiny'],
  ['【附歌词中字】Roselia 14th single—「Call the shots」FULL', 'Call the shots'],
  ['【附中日歌词】7.23更新 Roselia 9th single「FIRE BIRD」 p02 Ringing Bloom', 'Ringing Bloom'],
  ['《明日方舟》EP - What an Electromagnetic Night', 'What an Electromagnetic Night'],
  ['BEYOND《冷雨夜》百万豪装录音棚大声听', '冷雨夜'],
  ['『4K ⧸60』动态水印《鸣潮》先约电台EP2.8——千咲《破茧之华》', '破茧之华'],
  ['在百万豪装录音棚大声听 陈奕迅《富士山下》【Hi-res】', '富士山下'],
  ['『不可说』金铃过处, 片甲不留丨《百妖谱》主题曲翻唱', '不可说 (Cover)'],
  ['后弦《画风（《天行九歌》片尾曲）》百万豪装录音棚大声听', '画风'],
  ['小树 - 向日葵人生-动漫《我叫MT 第三季》', '向日葵人生'],
  ['Tokyo - Owl City', 'Tokyo'],
  ['ZEAL of proud - Roselia', 'ZEAL of proud'],
  ['Steve Vai （史蒂夫 范）- For The Love Of God（上帝的爱）Live', 'Steve Vai (Live)'],
  // `音阙诗听×李佳思 - 流浪的猫写情诗·…`: the side carrying the `×` credit is the
  // singer list, and the `·甜到掉牙的` tail is a subtitle — the title used to come
  // out as the artist line.
  ['【李佳思】音阙诗听×李佳思 - 流浪的猫写情诗·甜到掉牙的静享版（无损音质+中文字幕）', '流浪的猫写情诗'],
  // A quoted title keeps its `·`, which is why the tail rule only fires on a
  // segment no bracket settled.
  ['陈彼得《青玉案·元夕》百万豪装录音棚大声听', '青玉案·元夕'],
];
// These cases pin the regularized (Beta) names, which is the only mode that
// rewrites a title; traditional mode shows the file name verbatim.
const displayOf = (a, title) => a.run(`state.displayMode = 'canonical'; formatTrackDisplay(${JSON.stringify({ title, artist: 'Music', album: 'Music' })})`);

test('display titles are extracted from raw 视频 filenames', async () => {
  const a = await app();
  for (const [raw, expected] of titleCases) {
    assert.equal(displayOf(a, raw).title, expected, `raw: ${raw}`);
  }
});

test('distinct songs never collapse onto one display title', async () => {
  const a = await app();
  const titles = titleCases.map(([raw]) => displayOf(a, raw).title);
  assert.equal(new Set(titles).size, titles.length);
});

test('a title that cannot be parsed is kept instead of becoming a placeholder', async () => {
  const a = await app();
  const raw = '邦多利三次元乐队的实力如何？如果我拿出这一场，相信每一位观众都会被ras的演奏实力折服';
  assert.equal(displayOf(a, raw).title, raw);
  assert.doesNotMatch(displayOf(a, raw).title, /未命名歌曲/);
});

test('artist metadata is passed through unchanged for the track row', async () => {
  const a = await app();
  assert.equal(displayOf(a, '光年之外').artist, 'Music');
});

// A row already knows its singer, and that is the strongest signal for taking a
// credit out of its title. This is the library that reported the problem: canonical
// mode showed the singer *as* the song (`周杰伦 - 七里香` -> `周杰伦`, because a
// three-character song and a three-character singer tie on candidate score) or left
// the credit glued to the name (`光年之外-G.E.M.邓紫棋`). The singer column already
// carries the name, so the title must not repeat it.
const displayOfSinger = (a, title, artist) => a.run(`state.displayMode = 'canonical'; formatTrackDisplay(${JSON.stringify({ title, artist, raw_artist: artist, album: '', year: 0 })})`);
const creditedTitles = [
  ['光年之外-G.E.M.邓紫棋', 'G.E.M.邓紫棋', '光年之外'],
  ['句号-G.E.M.邓紫棋', 'G.E.M.邓紫棋', '句号'],
  ['多远都要在一起-G.E.M.邓紫棋', 'G.E.M.邓紫棋', '多远都要在一起'],
  ['泡沫-G.E.M.邓紫棋', 'G.E.M.邓紫棋', '泡沫'],
  ['周杰伦 - 七里香', '周杰伦', '七里香'],
  ['周杰伦 - 以父之名', '周杰伦', '以父之名'],
  ['周杰伦 - 晴天', '周杰伦', '晴天'],
  ['周杰伦 - 稻香', '周杰伦', '稻香'],
  ['周杰伦 - 花海', '周杰伦', '花海'],
  ['周杰伦 - 青花瓷', '周杰伦', '青花瓷'],
  ['就是爱你 - 陶喆', '陶喆', '就是爱你'],
  ['普通朋友 - 陶喆', '陶喆', '普通朋友'],
  ['林俊杰-黑夜问白天', '林俊杰', '黑夜问白天'],
  ['薛之谦-刚刚好', '薛之谦', '刚刚好'],
  ['陈奕迅-十年', '陈奕迅', '十年'],
  ['陈奕迅-富士山下', '陈奕迅', '富士山下'],
];

test('canonical mode cuts the row singer out of the title', async () => {
  const a = await app();
  for (const [raw, artist, expected] of creditedTitles) {
    const display = displayOfSinger(a, raw, artist);
    assert.equal(display.title, expected, `raw: ${raw} / singer: ${artist}`);
    assert.equal(display.artist, artist, `the singer column still carries the name: ${raw}`);
  }
});

test('the singer cut removes a whole credit segment, never a lookalike', async () => {
  const a = await app();
  // A Latin-Latin hyphen is not a credit separator, so `EXO-K` survives as one word.
  assert.equal(displayOfSinger(a, 'EXO-K《mama》百万豪装录音棚大声听', 'EXO-K').title, 'mama');
  // A duet credit is a different segment than the singer, so nothing is cut.
  assert.equal(displayOfSinger(a, '周杰伦&费玉清 - 千里之外', '周杰伦').title, '千里之外');
  // The singer named inside a quoted title is not a segment either.
  assert.equal(displayOfSinger(a, 'Beyond《冷雨夜》百万豪装录音棚大声听', 'Beyond').title, '冷雨夜');
  // A credit glued behind a closing bracket still splits, and the trailing marker
  // word becomes the existing `(Live)` suffix instead of staying in the name.
  assert.equal(displayOfSinger(a, 'steve vai （史蒂夫 范）- for the love of god（上帝的爱）live', 'Steve Vai').title, 'for the love of god (Live)');
  assert.equal(displayOfSinger(a, '小树-不安的前方-动漫《我叫MT 第三季》', '小树').title, '不安的前方');
  assert.equal(displayOfSinger(a, 'tokyo - owl city', 'Owl City').title, 'tokyo');
  assert.equal(displayOfSinger(a, '【中字4K·HiRes】「壱雫空」- MyGO!!!!!｜Divide⧸Unite p01 「壱雫空」', 'MyGO!!!!!').title, '壱雫空');
  assert.equal(displayOfSinger(a, '【附歌词中字】Roselia -「Dazzle the Destiny」【FULL】', 'Roselia').title, 'Dazzle the Destiny');
});

test('traditional mode still shows the file name when the singer is known', async () => {
  const a = await app();
  const raw = a.run(`state.displayMode = 'raw'; formatTrackDisplay(${JSON.stringify({ title: '周杰伦 - 七里香', artist: '周杰伦', raw_artist: '周杰伦' })}).title`);
  assert.equal(raw, '周杰伦 - 七里香');
});

// The two display modes. Traditional is the default and shows what the folder
// says; canonical (Beta) shows the regularized name plus the resolved singer,
// album and year. The server sends both sets of values, so switching modes is a
// rendering decision and must not depend on a rescan or a restart.
const reportedRow = {
  id: 'library-love',
  title: '在百万豪装录音棚大声听 爱情公寓3ost 陈韵若&陈每文《爱的回归线》【Hi-res】',
  artist: '陈韵若&陈每文',
  album: '爱情公寓3 OST',
  year: 2012,
  raw_artist: 'JLRS-LeoFM',
  raw_album: 'B站收藏',
  duration: 240,
  stream_url: '/api/library/library-love/stream',
  local_status: 'LOCAL',
};

test('traditional mode shows the folder names and hides every derived field', async () => {
  const a = await app();
  a.context.row = reportedRow;
  a.run("state.displayMode = 'raw'; syncLibrary([row]); renderLibrary();");
  const html = a.get('library-list').innerHTML;
  // The file's own name, verbatim.
  assert.match(html, /爱情公寓3ost 陈韵若&amp;陈每文《爱的回归线》【Hi-res】/);
  // The indexed value (for a Bilibili download, the uploader), not the resolved singer.
  assert.match(html, /JLRS-LeoFM/);
  assert.doesNotMatch(html, /2012 年/);
  assert.doesNotMatch(html, /爱情公寓3 OST/);
});

test('canonical mode shows the regularized name, the resolved singer, album and year', async () => {
  const a = await app();
  a.context.row = reportedRow;
  a.run("state.displayMode = 'canonical'; syncLibrary([row]); renderLibrary();");
  const html = a.get('library-list').innerHTML;
  assert.match(html, /爱的回归线/);
  assert.doesNotMatch(html, /爱情公寓3ost/);
  assert.match(html, /陈韵若&amp;陈每文/);
  assert.match(html, /爱情公寓3 OST/);
  assert.match(html, /2012 年/);
});

test('switching modes only re-renders: the row keeps both vocabularies searchable', async () => {
  const a = await app();
  a.context.row = reportedRow;
  a.run("syncLibrary([row]); renderLibrary();");
  // Searching by the uploader name still finds the row in the default mode.
  a.run("state.searchQuery = 'jlrs'; renderLibrary();");
  assert.match(a.get('library-list').innerHTML, /爱的回归线/);
  // ...and so does the resolved singer, without refetching anything.
  a.run("state.searchQuery = '陈韵若'; renderLibrary();");
  assert.match(a.get('library-list').innerHTML, /爱的回归线/);
});

test('saving the display mode persists it through the API and applies it locally', async () => {
  const a = await app();
  a.context.fetchHandler = url => url === '/api/settings/display-mode' ? json({ accepted: true, mode: 'canonical' }) : json({});
  await a.run("saveDisplayMode('canonical')");
  const put = a.requests.find(r => r.url === '/api/settings/display-mode' && r.options.method === 'PUT');
  assert.ok(put, 'the mode was written through the API');
  assert.equal(JSON.parse(put.options.body).mode, 'canonical');
  assert.equal(a.run('state.displayMode'), 'canonical');
});

test('an unreadable display-mode setting keeps the traditional names', async () => {
  const a = await app();
  a.context.fetchHandler = () => ({ ok: false, status: 503, statusText: 'ERR', json: async () => ({}) });
  await a.run('loadDisplayModeSettings()');
  assert.equal(a.run('state.displayMode'), 'raw');
});

