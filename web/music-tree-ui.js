/* Optional botanical renderer. The app owns data, mutations and audio; this
 * module owns only the seven-leaf viewport and the recommendation focus. */
(function (root) {
  'use strict';
  const PAGE_SIZE = 7;
  const clamp = (value, min, max) => Math.max(min, Math.min(max, Number(value) || 0));

  class LeafWindow {
    constructor() { this.items = []; this.start = 0; this.scope = ''; }
    get max() { return Math.max(0, this.items.length - PAGE_SIZE); }
    get visible() { return this.items.slice(this.start, this.start + PAGE_SIZE); }
    setItems(items, scope = '') {
      const oldId = this.items[this.start]?.id;
      const changedScope = this.scope !== scope;
      this.items = items;
      this.scope = scope;
      const anchor = changedScope ? 0 : items.findIndex((item) => item.id === oldId);
      this.start = Math.round(clamp(changedScope ? 0 : anchor < 0 ? this.start : anchor, 0, this.max));
      return this.visible;
    }
    setStart(value) { this.start = Math.round(clamp(value, 0, this.max)); return this.visible; }
    move(delta) { return this.setStart(this.start + delta); }
    group(direction) { return this.setStart(direction > 0 && this.start === this.max ? 0 : this.start + direction * PAGE_SIZE); }
    atRatio(ratio) { return this.setStart(clamp(ratio, 0, 1) * this.max); }
  }

  function orbitItems(items, focusId) {
    if (!items.length) return { focus: null, orbit: [], index: -1 };
    const index = Math.max(0, items.findIndex((item) => String(item.track_id) === String(focusId)));
    return { focus: items[index], index, orbit: Array.from({ length: Math.min(6, items.length - 1) }, (_, offset) => items[(index + offset + 1) % items.length]) };
  }

  function nextRecommendationIndex(index, length, direction) {
    if (!length) return 0;
    const step = length > 7 ? 7 : 1;
    return (index + direction * step + length) % length;
  }

  if (typeof module === 'object' && module.exports) module.exports = { LeafWindow, orbitItems, PAGE_SIZE, nextRecommendationIndex };
  if (typeof document === 'undefined') return;
  const el = (id) => document.getElementById(id);
  if (!el('tree-viewport')) return;
  const escape = (value) => String(value ?? '').replace(/[&<>"']/g, (char) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[char]));
  const icon = (name, cls = '') => `<svg class="ui-icon ${cls}" aria-hidden="true"><use href="#i-${name}" /></svg>`;
  const model = new LeafWindow();
  const viewport = el('tree-viewport');
  const list = el('library-list');
  const reducedMotion = root.matchMedia('(prefers-reduced-motion: reduce)');
  let libraryView = null;
  let recommendationView = null;
  let focusId = null;
  let desiredStart = 0;
  let turnTimer = null;
  let paintFrame = null;
  let wheelRemainder = 0;
  let lastWheel = 0;
  let signature = '';
  let scopeVersion = '';
  let dragPointer = null;
  let touchStart = null;
  let lastPlayingKey = null;
  let swayAnimation = null;
  function swayTree() {
    if (reducedMotion.matches) return;
    swayAnimation?.cancel();
    swayAnimation = document.querySelector('.tree-trunk').animate([{transform:'rotate(0deg)'},{transform:'rotate(.65deg)',offset:.3},{transform:'rotate(-.3deg)',offset:.65},{transform:'rotate(0deg)'}], {duration:850,easing:'ease-in-out'});
  }

  el('tree-svg-defs').innerHTML = `<svg xmlns="http://www.w3.org/2000/svg" width="0" height="0"><defs>
    <linearGradient id="leafBody" x1="0" y1="0" x2=".8" y2="1"><stop stop-color="#eff3dd" stop-opacity=".48"/><stop offset=".45" stop-color="#d5dfc0" stop-opacity=".42"/><stop offset="1" stop-color="#a9bc91" stop-opacity=".58"/></linearGradient>
    <radialGradient id="leafActive" cx=".55" cy=".35" r=".8"><stop stop-color="#fffbe0"/><stop offset=".53" stop-color="#e9e8b8"/><stop offset="1" stop-color="#b7c18a"/></radialGradient>
    <linearGradient id="stemGradient"><stop stop-color="#516d43"/><stop offset=".4" stop-color="#a9b078"/><stop offset=".6" stop-color="#e7deb0"/><stop offset="1" stop-color="#647c4c"/></linearGradient>
    <radialGradient id="goldBead" cx=".3" cy=".2" r=".8"><stop stop-color="#fffde4"/><stop offset=".45" stop-color="#dfcb83"/><stop offset="1" stop-color="#b09b52"/></radialGradient>
    <radialGradient id="dropThumb" cx=".35" cy=".3" r=".8"><stop stop-color="#f7fad9"/><stop offset=".57" stop-color="#d9e5b7"/><stop offset="1" stop-color="#a1b67a"/></radialGradient>
    <radialGradient id="waterBody" cx=".45" cy=".55" r=".7"><stop stop-color="#edf3d8" stop-opacity=".38"/><stop offset=".55" stop-color="#ceddbc" stop-opacity=".38"/><stop offset="1" stop-color="#a4bd91" stop-opacity=".50"/></radialGradient>
    <symbol id="i-play" viewBox="0 0 24 24"><path d="M8 5l11 7-11 7Z" fill="currentColor" stroke="none"/></symbol>
    <symbol id="i-pause" viewBox="0 0 24 24"><path d="M8 5v14M16 5v14" stroke-width="3.5"/></symbol>
    <symbol id="i-search" viewBox="0 0 24 24"><circle cx="10.5" cy="10.5" r="7.5"/><path d="m16 16 5 5"/></symbol>
    <symbol id="i-refresh" viewBox="0 0 24 24"><path d="M20 10a8 8 0 00-14-5L3 8m0-5v5h5M4 14a8 8 0 0014 5l3-3m0 5v-5h-5"/></symbol>
    <symbol id="i-download" viewBox="0 0 24 24"><path d="M12 3v12m-5-5 5 5 5-5M4 15v5h16v-5"/></symbol>
    <symbol id="i-headphones" viewBox="0 0 24 24"><path d="M4 13v-2a8 8 0 0116 0v2M4 11H3v8h4v-8Zm16 0h1v8h-4v-8Z"/></symbol>
    <symbol id="i-settings" viewBox="0 0 24 24"><path d="m9 3-1 3-3 1v4l-2 1 2 1v4l3 1 1 3h6l1-3 3-1v-4l2-1-2-1V7l-3-1-1-3Z"/><circle cx="12" cy="12" r="3"/></symbol>
    <symbol id="i-shuffle" viewBox="0 0 24 24"><path d="M3 6h3c5 0 7 12 12 12h3m-4-4 4 4-4 4M3 18h3c2 0 3-2 4-4m4-4c1-2 2-4 4-4h3m-4-4 4 4-4 4"/></symbol>
    <symbol id="i-left" viewBox="0 0 24 24"><path d="m14 5-7 7 7 7"/></symbol><symbol id="i-right" viewBox="0 0 24 24"><path d="m10 5 7 7-7 7"/></symbol>
    <symbol id="i-up" viewBox="0 0 24 24"><path d="m5 14 7-7 7 7"/></symbol><symbol id="i-down" viewBox="0 0 24 24"><path d="m5 10 7 7 7-7"/></symbol>
    <symbol id="i-heart" viewBox="0 0 24 24"><path d="M12 20S2 14 2 7.5C2 2 9 1 12 6c3-5 10-4 10 1.5C22 14 12 20 12 20Z"/></symbol>
    <symbol id="i-dislike" viewBox="0 0 24 24"><circle cx="12" cy="12" r="8"/><path d="m4 20 16-16M8 10h8"/></symbol>
    <symbol id="i-next" viewBox="0 0 24 24"><path d="m5 4 12 8L5 20Z" fill="currentColor"/><path d="M20 4v16" stroke-width="3"/></symbol>
    <symbol id="i-previous" viewBox="0 0 24 24"><path d="m19 4-12 8 12 8Z" fill="currentColor"/><path d="M4 4v16" stroke-width="3"/></symbol>
    <symbol id="i-volume" viewBox="0 0 24 24"><path d="M3 9h4l5-5v16l-5-5H3Zm13-2a7 7 0 010 10m3-13a11 11 0 010 16"/></symbol>
    <symbol id="i-lyrics" viewBox="0 0 24 24"><path d="M3 5h18M3 10h8M3 15h8M3 20h8M17 10v10m-3-7 3-3 3 3"/></symbol>
    <symbol id="mark-leaf-plain" viewBox="0 0 64 64"><path d="M5 57C7 27 26 17 59 5C58 38 44 57 5 57Z" fill="url(#leafBody)" stroke="#89975c" stroke-width="1.5"/><path d="M8 54Q30 43 56 9M19 46l1-15m11 7 14 1m-5-11 1-13" fill="none" stroke="#fff5c6" stroke-width=".9"/></symbol>
    <symbol id="mark-leaf" viewBox="0 0 64 64"><use href="#mark-leaf-plain"/><path d="M31 41V25l15-4v16M31 28l15-4" fill="none" stroke="#587445" stroke-width="3.5"/><ellipse cx="26" cy="43" rx="5.5" ry="4" fill="#658252"/><ellipse cx="41" cy="39" rx="5.5" ry="4" fill="#658252"/></symbol>
  </defs></svg>`;

  const leafPath = 'M498 77C380-14 153 13 8 26C93 51 96 125 264 138C360 151 441 111 498 77Z';
  function leafSvg() {
    return `<svg class="leaf-surface" viewBox="0 0 500 150" preserveAspectRatio="none" aria-hidden="true"><path class="leaf-body" d="${leafPath}"/><path class="leaf-rim" d="M488 76C377-4 159 22 20 29C101 53 105 118 264 132C365 144 434 107 488 76Z"/><g class="leaf-veins"><path d="M18 30Q219 39 490 77M54 42Q161 62 160 119M84 45Q190 27 283 12M149 48Q241 70 252 135M231 57Q302 22 365 29M288 63Q350 98 369 118M376 70Q413 59 451 62M164 118Q272 68 366 29M252 135Q321 82 413 48"/></g></svg>`;
  }
  const positions = [[0,56.7],[59,40.5],[0,54],[50,49],[0,49.5],[52,47],[0,53.5]];

  function librarySignature() {
    return JSON.stringify([model.start, libraryView.displayMode, libraryView.currentKey, libraryView.paused, model.visible.map((item) => [item.id, item.title, item.artist, item.starred, item.raw_artist, item.release_year, item.album])]);
  }

  function paintLibrary() {
    if (!libraryView) return;
    const nextSignature = librarySignature();
    updateRail();
    if (signature === nextSignature) return;
    signature = nextSignature;
    const active = document.activeElement;
    const focusRow = list.contains(active) ? active.closest('[data-library-id]') : null;
    const focusId = focusRow?.dataset.libraryId;
    const focusAction = active?.dataset?.action;
    if (!model.visible.length) {
      list.innerHTML = `<div class="empty-state">${libraryView.total ? '没有找到匹配的歌曲。<br>试试其他歌名，或切回全部歌曲。' : '音乐树还没有长出叶片。<br>从设置选择音乐库，或收藏右侧的推荐。'}</div>`;
      return;
    }
    list.innerHTML = model.visible.map((item, slot) => {
      const display = libraryView.display(item);
      const playing = libraryView.keyOf(item) === libraryView.currentKey;
      const isRight = slot % 2 === 1;
      const [left, width] = positions[slot];
      const label = `${display.title}${display.artist ? ` · ${display.artist}` : ''}`;
      return `<article class="tree-leaf ${isRight ? 'is-right' : 'is-left'} ${playing ? 'playing' : ''}" data-library-id="${escape(item.id)}" data-slot="${slot}" style="--slot:${slot};--leaf-left:${left}%;--leaf-width:${width}%" ${playing ? 'aria-current="true"' : ''}>
        ${leafSvg()}<span class="leaf-spectrum" aria-hidden="true">${Array.from({length:24}, () => '<i></i>').join('')}</span><span class="leaf-joint" aria-hidden="true"></span><div class="leaf-content"><button class="leaf-hit" data-action="play" aria-label="${playing && !libraryView.paused ? '暂停' : '播放'} ${escape(label)}" title="${escape(label)}"><span class="leaf-play">${icon(playing && !libraryView.paused ? 'pause' : 'play')}</span><span class="leaf-text"><span class="leaf-title">${escape(display.title)}</span><span class="leaf-artist">${escape(display.artist || '本地音乐')}</span></span></button>${playing ? '<span class="leaf-wave" aria-hidden="true"><i></i><i></i><i></i></span>' : `<button class="leaf-more" data-action="lyrics" aria-label="查看 ${escape(display.title)} 的歌词" title="查看歌词">···</button>`}</div></article>`;
    }).join('');
    if (focusId && focusAction) {
      const row = Array.from(list.querySelectorAll('[data-library-id]')).find((item) => item.dataset.libraryId === focusId);
      if (row) row.querySelector(`[data-action="${focusAction}"]`)?.focus({ preventScroll: true });
      else viewport.focus({ preventScroll: true });
    }
  }

  function updateRail() {
    const disabled = model.max === 0;
    const thumb = el('tree-scroll-thumb');
    const ratio = disabled ? 0 : desiredStart / model.max;
    thumb.style.top = `${ratio * 100}%`;
    thumb.setAttribute('aria-valuemax', String(model.max));
    thumb.setAttribute('aria-valuenow', String(model.start));
    thumb.setAttribute('aria-valuetext', model.items.length ? `第 ${model.start + 1} 至 ${Math.min(model.start + PAGE_SIZE, model.items.length)} 首，共 ${model.items.length} 首` : '没有歌曲');
    thumb.disabled = disabled;
    el('tree-up').disabled = el('tree-previous').disabled = desiredStart === 0;
    el('tree-down').disabled = desiredStart === model.max;
    el('tree-next').disabled = el('tree-regroup').disabled = disabled;
    el('library-count').textContent = model.items.length ? `${model.start + 1}–${Math.min(model.start + PAGE_SIZE, model.items.length)} / ${model.items.length}` : '0 首';
  }

  function commitTurn() {
    turnTimer = null;
    model.setStart(desiredStart);
    paintLibrary();
    viewport.classList.remove('is-turning');
  }

  function moveTo(next, source = 'wheel') {
    const previous = desiredStart;
    desiredStart = Math.round(clamp(next, 0, model.max));
    if (desiredStart === previous) return;
    updateRail();
    swayTree();
    if (source === 'drag' || reducedMotion.matches) {
      clearTimeout(turnTimer); turnTimer = null;
      if (paintFrame == null) paintFrame = requestAnimationFrame(() => { paintFrame = null; commitTurn(); });
      return;
    }
    viewport.style.setProperty('--turn-offset', desiredStart > previous ? '-7px' : '7px');
    viewport.classList.add('is-turning');
    if (turnTimer == null) turnTimer = setTimeout(commitTurn, 85);
  }

  function group(direction) {
    moveTo(direction > 0 && desiredStart >= model.max ? 0 : desiredStart + direction * PAGE_SIZE, 'group');
  }

  viewport.addEventListener('wheel', (event) => {
    if (event.ctrlKey || Math.abs(event.deltaX) > Math.abs(event.deltaY) || model.max === 0) return;
    event.preventDefault();
    const now = performance.now();
    if (now - lastWheel > 180 || Math.sign(event.deltaY) !== Math.sign(wheelRemainder)) wheelRemainder = 0;
    lastWheel = now;
    const scale = event.deltaMode === 1 ? 24 : event.deltaMode === 2 ? 420 : 1;
    wheelRemainder += event.deltaY * scale;
    const steps = Math.trunc(wheelRemainder / 65);
    if (steps) { wheelRemainder -= steps * 65; moveTo(desiredStart + steps); }
  }, { passive: false });
  viewport.addEventListener('keydown', (event) => {
    if (event.target.closest('input,select,textarea')) return;
    const target = ({ ArrowDown: desiredStart + 1, ArrowUp: desiredStart - 1, PageDown: desiredStart + PAGE_SIZE, PageUp: desiredStart - PAGE_SIZE, Home: 0, End: model.max })[event.key];
    if (target == null) return;
    event.preventDefault(); moveTo(target, 'keyboard');
  });
  viewport.addEventListener('pointerdown', (event) => { if (event.pointerType === 'touch' && !event.target.closest('.tree-scroll-rail')) touchStart = { y: event.clientY, start: desiredStart }; });
  viewport.addEventListener('pointermove', (event) => { if (touchStart && event.pointerType === 'touch') moveTo(touchStart.start + Math.round((touchStart.y - event.clientY) / 48), 'drag'); });
  const endTouch = () => { touchStart = null; };
  viewport.addEventListener('pointerup', endTouch); viewport.addEventListener('pointercancel', endTouch);
  const rail = el('tree-scroll-track');
  function fromPointer(event) { const box = rail.getBoundingClientRect(); moveTo(clamp((event.clientY - box.top) / Math.max(1, box.height), 0, 1) * model.max, 'drag'); }
  rail.addEventListener('pointerdown', (event) => { if (!model.max || event.button !== 0) return; event.preventDefault(); dragPointer = event.pointerId; rail.classList.add('is-dragging'); rail.setPointerCapture(event.pointerId); fromPointer(event); });
  rail.addEventListener('pointermove', (event) => { if (dragPointer === event.pointerId) fromPointer(event); });
  const endDrag = (event) => { if (dragPointer === event.pointerId) { dragPointer = null; rail.classList.remove('is-dragging'); if (rail.hasPointerCapture(event.pointerId)) rail.releasePointerCapture(event.pointerId); } };
  rail.addEventListener('pointerup', endDrag); rail.addEventListener('pointercancel', endDrag);
  el('tree-up').addEventListener('click', () => moveTo(desiredStart - 1));
  el('tree-down').addEventListener('click', () => moveTo(desiredStart + 1));
  el('tree-previous').addEventListener('click', () => group(-1));
  el('tree-next').addEventListener('click', () => group(1));
  el('tree-regroup').addEventListener('click', () => group(1));
  el('tree-scope').addEventListener('change', () => libraryView?.refresh());

  function paintRecommendations() {
    if (!recommendationView) return;
    const { items, display, keyOf, currentKey, paused, pendingLikes, pendingDislikes } = recommendationView;
    const group = orbitItems(items, focusId);
    focusId = group.focus?.track_id || null;
    el('rec-position').textContent = items.length ? `${group.index + 1} / ${items.length}` : '';
    el('rec-previous').disabled = el('rec-next').disabled = items.length < 2;
    el('water-discover').disabled = items.length < 2;
    const recList = el('recommendation-list');
    const active = recList.contains(document.activeElement) ? document.activeElement : null;
    const activeTrack = active?.closest('[data-track-id]')?.dataset.trackId;
    const activeAction = active?.dataset.action;
    if (!group.focus) { recList.innerHTML = '<div class="empty-state">今日推荐正在准备中。<br>先从音乐树选一首吧。</div>'; return; }
    const item = group.focus;
    const data = display(item);
    const playing = keyOf(item) === currentKey && !paused;
    recList.innerHTML = `<article class="ripple-focus ${playing ? 'playing' : ''}" data-track-id="${escape(item.track_id)}"><h3 class="focus-title" title="${escape(data.title)}">${escape(data.title)}</h3><span class="focus-artist" title="${escape(data.artist)}">${escape(data.artist || '为你推荐')}</span><button class="focus-play" data-action="play" aria-label="${playing ? '暂停' : '试听'} ${escape(data.title)}">${icon(playing ? 'pause' : 'play')}<span>${playing ? '暂停' : '试听'}</span></button><div class="focus-feedback"><button class="ripple-feedback ${item.liked ? 'liked' : ''}" data-action="like" aria-label="${item.liked ? '取消喜欢' : '喜欢'} ${escape(data.title)}" aria-pressed="${!!item.liked}" ${pendingLikes.has(item.track_id) ? 'disabled' : ''}>${icon('heart')}</button><button class="ripple-feedback ${item.disliked ? 'disliked' : ''}" data-action="dislike" aria-label="${item.disliked ? '取消讨厌' : '少推荐这首歌'}" aria-pressed="${!!item.disliked}" ${pendingDislikes.has(item.track_id) ? 'disabled' : ''}>${icon('dislike')}</button></div></article>${group.orbit.map((entry, index) => {
      const text = display(entry);
      return `<article class="ripple-orbit" data-orbit="${index}" data-track-id="${escape(entry.track_id)}"><button class="orbit-select" data-action="select" title="${escape(text.title)}" aria-label="选择推荐 ${escape(text.title)}">${escape(text.title)}</button><button class="orbit-play" data-action="play" aria-label="试听 ${escape(text.title)}">${icon('play')}</button></article>`;
    }).join('')}`;
    if (activeTrack && activeAction) {
      const row = Array.from(recList.querySelectorAll('[data-track-id]')).find((entry) => entry.dataset.trackId === activeTrack);
      row?.querySelector(`[data-action="${activeAction}"]`)?.focus({ preventScroll: true });
    }
  }
  el('recommendation-list').addEventListener('click', (event) => {
    if (!event.target.closest('[data-action="select"],[data-action="play"]')) return;
    const selectedId = event.target.closest('[data-track-id]')?.dataset.trackId;
    if (!selectedId || selectedId === focusId) return;
    // Let the shared app click handler consume the original song before replacing its DOM.
    if (event.target.closest('[data-action="play"]')) {
      queueMicrotask(() => { focusId = selectedId; promoteRecommendation(); });
      return;
    }
    focusId = event.target.closest('[data-track-id]')?.dataset.trackId;
    promoteRecommendation();
    el('recommendation-list').querySelector('.focus-play')?.focus({ preventScroll: true });
  });
  function promoteRecommendation() {
    const before = new Map(Array.from(el('recommendation-list').children, row => [row.dataset.trackId, row.getBoundingClientRect()]));
    paintRecommendations();
    if (reducedMotion.matches) return;
    for (const row of el('recommendation-list').children) {
      const old = before.get(row.dataset.trackId);
      const now = row.getBoundingClientRect();
      if (old && now.width && now.height) row.animate([
        { transform: `translate(${old.x-now.x}px,${old.y-now.y}px) scale(${old.width/now.width},${old.height/now.height})`, opacity:.55 },
        { transform:'none', opacity:1 }
      ], {duration:560, easing:'cubic-bezier(.2,.75,.2,1)'});
    }
  }
  function nextRecommendation(direction) {
    const items = recommendationView?.items || [];
    if (!items.length) return;
    const index = Math.max(0, items.findIndex((item) => item.track_id === focusId));
    focusId = items[nextRecommendationIndex(index, items.length, direction)].track_id;
    paintRecommendations();
  }
  let waterFrame = null;
  let pendingTurn = null;
  function discover(direction, event) {
    if (pendingTurn != null) return;
    const layer = el('water-ripples');
    const recList = el('recommendation-list');
    if (waterFrame != null) cancelAnimationFrame(waterFrame);
    layer.replaceChildren();
    if (reducedMotion.matches) { nextRecommendation(direction); return; }
    const box = layer.getBoundingClientRect();
    const x = event?.detail ? event.clientX - box.left : box.width * .5;
    const y = event?.detail ? event.clientY - box.top : box.height * .66;
    const ns = 'http://www.w3.org/2000/svg';
    const svg = document.createElementNS(ns, 'svg');
    svg.setAttribute('viewBox', `0 0 ${box.width} ${box.height}`);
    svg.classList.add('discovery-surface');
    const rings = Array.from({length: 3}, () => {
      const ring = document.createElementNS(ns, 'circle');
      ring.setAttribute('cx', x); ring.setAttribute('cy', y); ring.setAttribute('r', '0');
      ring.setAttribute('fill', 'none'); ring.setAttribute('stroke', '#fff9ce');
      ring.setAttribute('stroke-width', '3'); ring.classList.add('discovery-wave');
      svg.append(ring); return ring;
    });
    layer.append(svg);
    recList.classList.add('water-turning');
    pendingTurn = setTimeout(() => {
      pendingTurn = null;
      nextRecommendation(direction);
      recList.classList.remove('water-turning');
    }, 240);
    const began = performance.now();
    const radius = Math.hypot(box.width, box.height) * .8;
    function draw(now) {
      const elapsed = now - began;
      rings.forEach((ring, i) => {
        const t = clamp((elapsed - i * 150) / 1550, 0, 1);
        ring.setAttribute('r', String(radius * (1 - (1 - t) ** 2)));
        ring.setAttribute('opacity', String((1 - t) * .95));
      });
      if (elapsed < 1850) waterFrame = requestAnimationFrame(draw);
      else { waterFrame = null; layer.replaceChildren(); }
    }
    waterFrame = requestAnimationFrame(draw);
  }
  el('water-discover').addEventListener('click', (event) => discover(1, event));
  el('rec-previous').addEventListener('click', () => discover(-1));
  el('rec-next').addEventListener('click', () => discover(1));
  root.addEventListener('pagehide', () => {
    clearTimeout(pendingTurn); pendingTurn = null;
    if (waterFrame != null) cancelAnimationFrame(waterFrame);
    waterFrame = null;
    el('water-ripples').replaceChildren();
    el('recommendation-list').classList.remove('water-turning');
  });
  document.addEventListener('visibilitychange', () => document.body.classList.toggle('water-paused', document.hidden));
  el('tree-player-like').addEventListener('click', () => recommendationView?.likeCurrent());
  const artMarkup = '<svg viewBox="0 0 64 64" aria-hidden="true"><use href="#mark-leaf-plain" /></svg>';
  el('player-art').innerHTML = artMarkup;


  const audio = el('audio-player');
  let spectrumContext = null, analyser = null, capture = null, bins = null, spectrumFrame = null, spectrumLast = 0;
  function stopSpectrum() {
    if (spectrumFrame != null) cancelAnimationFrame(spectrumFrame);
    spectrumFrame = null;
    list.querySelectorAll('.leaf-spectrum i').forEach(bar => bar.style.removeProperty('--level'));
  }
  function drawSpectrum(now) {
    if (audio.paused || document.hidden || reducedMotion.matches) { stopSpectrum(); return; }
    if (now - spectrumLast > 45) {
      spectrumLast = now;
      analyser.getByteFrequencyData(bins);
      list.querySelectorAll('.playing .leaf-spectrum i').forEach((bar,i) => {
        const bin = Math.min(bins.length-1, Math.floor(2 * Math.pow(1.22,i)));
        bar.style.setProperty('--level', String(.05 + bins[bin]/255 * .95));
      });
    }
    spectrumFrame = requestAnimationFrame(drawSpectrum);
  }
  async function startSpectrum() {
    if (audio.paused || document.hidden || reducedMotion.matches) return;
    try {
      if (!analyser) {
        const captureAudio = audio.captureStream || audio.mozCaptureStream;
        if (!captureAudio || !root.AudioContext) return;
        capture = captureAudio.call(audio);
        if (!capture.getAudioTracks().length) { capture.getTracks().forEach(track => track.stop()); capture=null; return; }
        spectrumContext = new root.AudioContext();
        analyser = spectrumContext.createAnalyser(); analyser.fftSize = 1024; analyser.smoothingTimeConstant=.82;
        spectrumContext.createMediaStreamSource(capture).connect(analyser);
        bins = new Uint8Array(analyser.frequencyBinCount);
      }
      const context = spectrumContext;
      await context.resume();
      if (context !== spectrumContext || !analyser) return;
      if (spectrumFrame == null && !audio.paused && !document.hidden) spectrumFrame=requestAnimationFrame(drawSpectrum);
    } catch { stopSpectrum(); } // Visual enhancement must never interfere with playback.
  }
  function resetSpectrum() {
    stopSpectrum(); capture?.getTracks().forEach(track => track.stop()); capture=null;
    void spectrumContext?.close(); spectrumContext=null; analyser=null;
  }
  audio.addEventListener('emptied', resetSpectrum);
  audio.addEventListener('playing', startSpectrum);
  audio.addEventListener('pause', stopSpectrum);
  audio.addEventListener('ended', stopSpectrum);
  document.addEventListener('pointerdown', () => { if (spectrumContext?.state === 'suspended') void startSpectrum(); }, {passive:true});
  document.addEventListener('visibilitychange', () => document.hidden ? stopSpectrum() : void startSpectrum());
  let pointerFrame = null, pointerX = .5, pointerY = .5;
  document.addEventListener('pointermove', event => {
    if (reducedMotion.matches || event.pointerType === 'touch') return;
    pointerX=event.clientX/root.innerWidth; pointerY=event.clientY/root.innerHeight;
    if (pointerFrame == null) pointerFrame=requestAnimationFrame(() => {
      pointerFrame=null;
      document.body.style.setProperty('--water-x', `${pointerX*100}%`);
      document.body.style.setProperty('--water-y', `${pointerY*100}%`);
      document.body.style.setProperty('--water-drift-x', `${(pointerX-.5)*18}px`);
      document.body.style.setProperty('--water-drift-y', `${(pointerY-.5)*12}px`);
    });
  }, {passive:true});
  root.addEventListener('pagehide', () => {
    stopSpectrum(); swayAnimation?.cancel();
    if (pointerFrame != null) cancelAnimationFrame(pointerFrame);
    pointerFrame=null;
    resetSpectrum();
  });

  root.MusicTreeUI = {
    filterLibrary(items) { return el('tree-scope').value === 'lyrics' ? items.filter((item) => !!item.lyrics_url) : items; },
    renderLibrary(view) {
      libraryView = view;
      if (lastPlayingKey !== view.currentKey) { if (lastPlayingKey != null) swayTree(); lastPlayingKey = view.currentKey; }
      const scope = JSON.stringify([view.searchQuery, view.librarySort, el('tree-scope').value]);
      if (scopeVersion !== scope) { clearTimeout(turnTimer); turnTimer = null; wheelRemainder = 0; viewport.classList.remove('is-turning'); }
      scopeVersion = scope;
      model.setItems(view.items, scope);
      if (turnTimer == null && paintFrame == null) desiredStart = model.start;
      else desiredStart = Math.min(desiredStart, model.max);
      el('library-more').hidden = true;
      document.body.dataset.playing = String(!view.paused);
      paintLibrary();
    },
    renderRecommendations(view) {
      recommendationView = view;
      paintRecommendations();
      const item = view.items.find((entry) => view.keyOf(entry) === view.currentKey);
      const like = el('tree-player-like');
      like.hidden = !item;
      like.disabled = !!item && view.pendingLikes.has(item.track_id);
      like.classList.toggle('liked', !!item?.liked);
      like.setAttribute('aria-pressed', String(!!item?.liked));
      like.setAttribute('aria-label', item?.liked ? '取消喜欢当前推荐' : '喜欢当前推荐');
    },
    playerArt() { el('player-art').innerHTML = artMarkup; },
    setPlayIcon(playing) { el('play-toggle').innerHTML = icon(playing ? 'pause' : 'play'); document.body.dataset.playing = String(playing); },
    // Exposed for the keyboard/page controls and an explicit preview harness.
    viewStart() { return model.start; },
  };
  root.addEventListener('pagehide', () => { clearTimeout(turnTimer); if (paintFrame != null) cancelAnimationFrame(paintFrame); });
})(globalThis);
