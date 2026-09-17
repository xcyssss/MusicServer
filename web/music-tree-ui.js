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
    const start = Math.floor(index / PAGE_SIZE) * PAGE_SIZE;
    const batch = items.slice(start, start + PAGE_SIZE);
    // Promotion swaps positions within a stable batch; the final partial batch
    // must never wrap and pull already-seen songs back into the current group.
    [batch[0], batch[index - start]] = [batch[index - start], batch[0]];
    return { focus: batch[0], index, orbit: batch.slice(1) };
  }

  function nextRecommendationIndex(index, length, direction) {
    if (!length) return 0;
    const pages = Math.ceil(length / PAGE_SIZE);
    const page = Math.floor(clamp(index, 0, length - 1) / PAGE_SIZE);
    return ((page + Math.sign(direction) + pages) % pages) * PAGE_SIZE;
  }

  // A continuous stem in library coordinates: scrolling samples a different
  // section of the same curve. Leaf joints and the SVG share these anchors.
  function treeGeometry(scroll) {
    const x = (index) => 552 + 40 * Math.sin(index * .82 + .3) + 12 * Math.sin(index * 1.53);
    const slope = (index) => 32.8 * Math.cos(index * .82 + .3) + 18.36 * Math.cos(index * 1.53);
    const number = (value) => Number(value.toFixed(3));
    const anchor = (slot) => ({ x: number(x(scroll + slot)), y: number(73.5 + slot * 91) });
    const first = anchor(-2);
    let path = `M${first.x} ${first.y}`;
    for (let slot = -2; slot < 9; slot++) {
      const a = anchor(slot), b = anchor(slot + 1);
      path += `C${number(a.x + slope(scroll + slot) / 3)} ${number(a.y + 91 / 3)} ${number(b.x - slope(scroll + slot + 1) / 3)} ${number(b.y - 91 / 3)} ${b.x} ${b.y}`;
    }
    return { path, anchors: Array.from({ length: PAGE_SIZE }, (_, slot) => anchor(slot)), sprigs: [0.48,1.55,2.5,3.6,4.5,5.65].map(anchor) };
  }

  function playbackFocus(items, keyOf, currentKey, previousKey, focusId) {
    if (currentKey === previousKey) return focusId;
    return items.find((item) => keyOf(item) === currentKey)?.track_id ?? focusId;
  }

  // A bounded audio envelope emits travelling crests; silence adds no pulses.
  class MusicRipples {
    constructor() { this.clear(); }
    clear() { this.rings = []; this.time = 0; this.last = -1200; this.envelope = 0; this.serial = 0; this.interval = 750; }
    sample(bins, delta, active) {
      if (!active) { this.clear(); return this.rings; }
      this.time += Math.min(100, delta);
      let power = 0;
      const end = Math.min(bins?.length || 0, 90);
      for (let i = 2; i < end; i++) power += (bins[i] / 255) ** 2;
      // Remote media may be audible but unavailable to captureStream (CORS).
      // Use quiet playback ripples then, not fabricated frequency samples.
      const energy = bins ? Math.sqrt(power / Math.max(1, end - 2)) : .11;
      const attack = energy - this.envelope;
      this.envelope += (energy - this.envelope) * .28;
      this.rings = this.rings.filter(ring => this.time - ring.born < ring.life);
      if (energy > .045 && this.time - this.last > (!bins ? 1750 : attack > .025 ? 580 : this.interval)) {
        // Golden-angle phases give successive wave fronts a different current,
        // without randomizing geometry every frame or synchronizing every crest.
        const phase = this.serial++ * 2.399963;
        this.rings.push({born:this.time, strength:Math.min(1,.13+energy*1.1), phase, life:3200+Math.sin(phase)*260});
        this.interval = 1130 + Math.sin(phase + 1) * 170;
        if (this.rings.length > 5) this.rings.shift();
        this.last = this.time;
      }
      return this.rings;
    }
  }

  // Low-frequency curvature stays continuous through 2π. Shared by music and
  // click waves, so neither effect looks like a scaled circular UI outline.
  function waterCurve(radius, phase, from = 0, span = Math.PI * 2, flatten = .7) {
    return Array.from({length:65}, (_, i) => {
      const angle = from + span * i / 64;
      const bend = 1 + .043*Math.sin(3*angle+phase) + .025*Math.cos(2*angle-phase*.7);
      return {x:Math.cos(angle)*radius*bend, y:Math.sin(angle)*radius*flatten*bend};
    });
  }

  if (typeof module === 'object' && module.exports) module.exports = { LeafWindow, orbitItems, PAGE_SIZE, nextRecommendationIndex, treeGeometry, playbackFocus, MusicRipples, waterCurve };
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
  let recommendationSignature = '', orbitMotionDeadline = 0;
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
  let lastRecommendationKey = null;
  let stemScroll = 0, stemTarget = 0, stemFrame = null;
  const trunkPaths = document.querySelectorAll('.tree-trunk > path');
  function positionLeaves(geometry) {
    list.querySelectorAll('.tree-leaf').forEach((leaf, slot) => {
      const joint = geometry.anchors[slot].x / 10;
      leaf.style.setProperty('--leaf-left', `${slot % 2 ? joint : 0}%`);
      leaf.style.setProperty('--leaf-width', `${slot % 2 ? 99 - joint : joint}%`);
    });
  }
  function drawTree() {
    const geometry = treeGeometry(stemScroll);
    trunkPaths.forEach(path => path.setAttribute('d', geometry.path));
    document.querySelectorAll('.stem-sprig').forEach((sprig,index) => {
      const point=geometry.sprigs[index];
      sprig.setAttribute('transform', `translate(${point.x} ${point.y}) scale(${index%2 ? -1 : 1} 1)`);
    });
    positionLeaves(geometry);
  }
  function flowTree(target, immediate = false) {
    if (target === stemTarget && !immediate) return;
    if (stemFrame != null) cancelAnimationFrame(stemFrame);
    stemFrame = null; stemTarget = target;
    if (immediate || reducedMotion.matches) { stemScroll = target; drawTree(); return; }
    const from = stemScroll, began = performance.now();
    function frame(now) {
      const progress = clamp((now - began) / 440, 0, 1);
      stemScroll = from + (target - from) * (1 - (1 - progress) ** 3);
      drawTree();
      stemFrame = progress < 1 ? requestAnimationFrame(frame) : null;
    }
    stemFrame = requestAnimationFrame(frame);
  }

  el('tree-svg-defs').innerHTML = `<svg xmlns="http://www.w3.org/2000/svg" width="0" height="0"><defs>
    <linearGradient id="leafBody" x1="0" y1="0" x2=".8" y2="1"><stop stop-color="#faffef" stop-opacity=".7"/><stop offset=".28" stop-color="#c5dcc0" stop-opacity=".18"/><stop offset=".68" stop-color="#e9f4d9" stop-opacity=".12"/><stop offset="1" stop-color="#7c9e6d" stop-opacity=".38"/></linearGradient>
    <radialGradient id="leafActive" cx=".55" cy=".35" r=".8"><stop stop-color="#fffedb" stop-opacity=".76"/><stop offset=".53" stop-color="#f3edb7" stop-opacity=".26"/><stop offset="1" stop-color="#a5ba7a" stop-opacity=".46"/></radialGradient>
    <linearGradient id="stemGradient"><stop stop-color="#516d43"/><stop offset=".4" stop-color="#a9b078"/><stop offset=".6" stop-color="#e7deb0"/><stop offset="1" stop-color="#647c4c"/></linearGradient>
    <radialGradient id="goldBead" cx=".3" cy=".2" r=".8"><stop stop-color="#fffde4"/><stop offset=".45" stop-color="#dfcb83"/><stop offset="1" stop-color="#b09b52"/></radialGradient>
    <radialGradient id="dropThumb" cx=".35" cy=".3" r=".8"><stop stop-color="#f7fad9"/><stop offset=".57" stop-color="#d9e5b7"/><stop offset="1" stop-color="#a1b67a"/></radialGradient>
    <radialGradient id="waterBody" cx=".36" cy=".42" r=".72"><stop stop-color="#f5fff0" stop-opacity=".025"/><stop offset=".48" stop-color="#c6e7d8" stop-opacity=".04"/><stop offset=".82" stop-color="#70a994" stop-opacity=".12"/><stop offset="1" stop-color="#b4d7be" stop-opacity=".07"/></radialGradient>
    <symbol id="i-play" viewBox="0 0 24 24"><path d="M8 5l11 7-11 7Z" fill="currentColor" stroke="none"/></symbol>
    <symbol id="i-pause" viewBox="0 0 24 24"><path d="M8 5v14M16 5v14" stroke-width="3.5"/></symbol>
    <symbol id="i-search" viewBox="0 0 24 24"><circle cx="10.5" cy="10.5" r="7.5"/><path d="m16 16 5 5"/></symbol>
    <symbol id="i-refresh" viewBox="0 0 24 24"><path d="M20 10a8 8 0 00-14-5L3 8m0-5v5h5M4 14a8 8 0 0014 5l3-3m0 5v-5h-5"/></symbol>
    <symbol id="i-download" viewBox="0 0 24 24"><path d="M12 3v12m-5-5 5 5 5-5M4 15v5h16v-5"/></symbol>
    <symbol id="i-headphones" viewBox="0 0 24 24"><path d="M4 13v-2a8 8 0 0116 0v2M4 11H3v8h4v-8Zm16 0h1v8h-4v-8Z"/></symbol>
    <symbol id="i-settings" viewBox="0 0 30 20"><path d="M2 5h8m5 0h13M2 15h16m5 0h5"/><circle cx="12.5" cy="5" r="2.5"/><circle cx="20.5" cy="15" r="2.5"/></symbol>
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

  el('stem-details').innerHTML = Array.from({length:6},(_,index)=>`<g class="stem-sprig" style="--sprig-delay:${-index*1.3}s"><g class="sprig-leaves"><path class="sprig-body" d="M0 0C-29-5-41-31-38-49C-13-39-2-22 0 0Z"/><path class="sprig-vein" d="M0 0Q-17-29-34-43M-13-20l-15-6M-22-30l1-9"/><path class="sprig-body small" d="M-3-4Q6-33 29-35Q27-10-3-4Z"/><path class="sprig-vein" d="M-3-4Q15-16 25-31"/><circle class="stem-dew" cx="-8" cy="-10" r="2.8"/></g></g>`).join('');

  const leafPath = 'M498 77C380-14 153 13 8 26C93 51 96 125 264 138C360 151 441 111 498 77Z';
  function leafSvg() {
    return `<svg class="leaf-surface" viewBox="0 0 500 150" preserveAspectRatio="none" aria-hidden="true"><path class="leaf-body" d="${leafPath}"/><path class="leaf-rim" d="M488 76C377-4 159 22 20 29C101 53 105 118 264 132C365 144 434 107 488 76Z"/><g class="leaf-veins"><path d="M18 30Q219 39 490 77M54 42Q161 62 160 119M84 45Q190 27 283 12M149 48Q241 70 252 135M231 57Q302 22 365 29M288 63Q350 98 369 118M376 70Q413 59 451 62M164 118Q272 68 366 29M252 135Q321 82 413 48"/></g></svg>`;
  }

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
      const joint = treeGeometry(stemScroll).anchors[slot].x / 10;
      const [left, width] = isRight ? [joint, 99 - joint] : [0, joint];
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
    flowTree(desiredStart);
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
    const nextSignature = JSON.stringify([focusId, currentKey, paused, items.map(item => [item.track_id, display(item), item.liked, item.disliked, pendingLikes.has(item.track_id), pendingDislikes.has(item.track_id)])]);
    if (recommendationSignature === nextSignature) return;
    recommendationSignature = nextSignature;
    const page = Math.floor(group.index / PAGE_SIZE) + 1;
    const pages = Math.ceil(items.length / PAGE_SIZE);
    el('rec-position').textContent = items.length ? `${page} / ${pages} 组 · ${items.length} 首` : '';
    const nextLabel = page === pages ? '已看完今日推荐，重新浏览第一组' : '下一批推荐';
    const previousLabel = page === 1 ? '浏览今日推荐的最后一组' : '上一批推荐';
    for (const [id, label] of [['rec-next', nextLabel], ['rec-previous', previousLabel], ['water-discover', `泛起波纹，${nextLabel}`]]) {
      el(id).setAttribute('aria-label', label);
      el(id).title = pages <= 1 ? '今日推荐已全部展示' : label;
      el(id).disabled = pages <= 1;
    }
    const recList = el('recommendation-list');
    const remainingMotion = orbitMotionDeadline - performance.now();
    const before = remainingMotion > 0 ? new Map(Array.from(recList.children, row => [row.dataset.trackId, row.getBoundingClientRect()])) : null;
    const active = recList.contains(document.activeElement) ? document.activeElement : null;
    const activeTrack = active?.closest('[data-track-id]')?.dataset.trackId;
    const activeAction = active?.dataset.action;
    if (!group.focus) { recList.innerHTML = '<div class="empty-state">今日推荐正在准备中。<br>先从音乐树选一首吧。</div>'; return; }
    const item = group.focus;
    const data = display(item);
    const playing = keyOf(item) === currentKey && !paused;
    recList.innerHTML = `<article class="ripple-focus ${playing ? 'playing' : ''}" data-track-id="${escape(item.track_id)}"><h3 class="focus-title" title="${escape(data.title)}">${escape(data.title)}</h3><span class="focus-artist" title="${escape(data.artist)}">${escape(data.artist || '为你推荐')}</span><button class="focus-play" data-action="play" aria-label="${playing ? '暂停' : '试听'} ${escape(data.title)}">${icon(playing ? 'pause' : 'play')}<span>${playing ? '暂停' : '试听'}</span></button><div class="focus-feedback"><button class="ripple-feedback ${item.liked ? 'liked' : ''}" data-action="like" aria-label="${item.liked ? '取消喜欢' : '喜欢'} ${escape(data.title)}" aria-pressed="${!!item.liked}" ${pendingLikes.has(item.track_id) ? 'disabled' : ''}>${icon('heart')}</button><button class="ripple-feedback ${item.disliked ? 'disliked' : ''}" data-action="dislike" aria-label="${item.disliked ? '取消讨厌' : '少推荐这首歌'}" aria-pressed="${!!item.disliked}" ${pendingDislikes.has(item.track_id) ? 'disabled' : ''}>${icon('dislike')}</button></div></article>${group.orbit.map((entry, index) => {
      const text = display(entry);
      return `<article class="ripple-orbit ${keyOf(entry) === currentKey && !paused ? 'playing' : ''}" data-orbit="${index}" data-track-id="${escape(entry.track_id)}"><button class="orbit-select" data-action="select" title="${escape(text.title)}" aria-label="选择推荐 ${escape(text.title)}">${escape(text.title)}</button><button class="orbit-play" data-action="play" aria-label="试听 ${escape(text.title)}">${icon('play')}</button></article>`;
    }).join('')}`;
    if (before && !reducedMotion.matches) animateOrbits(before, remainingMotion);
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
      queueMicrotask(() => { if (focusId !== selectedId) { focusId = selectedId; promoteRecommendation(); } });
      return;
    }
    focusId = event.target.closest('[data-track-id]')?.dataset.trackId;
    promoteRecommendation();
    el('recommendation-list').querySelector('.focus-play')?.focus({ preventScroll: true });
  });
  function promoteRecommendation() {
    orbitMotionDeadline = performance.now() + 680;
    paintRecommendations();
  }
  function animateOrbits(before, duration) {
    for (const row of el('recommendation-list').children) {
      const old = before.get(row.dataset.trackId);
      const now = row.getBoundingClientRect();
      if (old && now.width && now.height) row.animate([
        { transform: `translate(${old.x-now.x}px,${old.y-now.y}px) scale(${old.width/now.width},${old.height/now.height})`, opacity:.55 },
        { transform:'none', opacity:1 }
      ], {duration, easing:'cubic-bezier(.22,.61,.36,1)'});
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
    svg.innerHTML = '<defs><linearGradient id="discovery-glint"><stop stop-color="#faffed" stop-opacity="0"/><stop offset=".24" stop-color="#faffed" stop-opacity=".75"/><stop offset=".56" stop-color="#effcce" stop-opacity=".2"/><stop offset=".82" stop-color="#faffed" stop-opacity=".65"/><stop offset="1" stop-color="#faffed" stop-opacity="0"/></linearGradient></defs>';
    const rings = Array.from({length: 3}, () => {
      const ring = document.createElementNS(ns, 'path');
      ring.setAttribute('fill', 'none'); ring.setAttribute('stroke', 'url(#discovery-glint)');
      ring.setAttribute('stroke-width', '1.8'); ring.classList.add('discovery-wave');
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
        const t = clamp((elapsed - i * 210) / 2150, 0, 1);
        const points = waterCurve(radius * (1 - (1 - t) ** 1.45), i*2.4+t*.65);
        ring.setAttribute('d', points.map((p,index) => `${index ? 'L' : 'M'}${x+p.x} ${y+p.y}`).join(' '));
        ring.setAttribute('opacity', String(Math.sin(Math.PI*t)**.8 * (1-t*.4)));
      });
      if (elapsed < 2580 && !document.hidden && !reducedMotion.matches) waterFrame = requestAnimationFrame(draw);
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
  const musicWater = document.createElement('canvas');
  musicWater.className = 'recommendation-water'; musicWater.setAttribute('aria-hidden','true');
  el('water-discover').parentElement.appendChild(musicWater);
  const musicPaint = musicWater.getContext('2d');
  const musicRipples = new MusicRipples();
  let musicTime = null, musicOrigin = null;
  function clearMusicWater() {
    musicRipples.clear();
    musicTime = null;
    musicOrigin = null;
    musicPaint?.clearRect(0,0,musicWater.width,musicWater.height);
  }
  function drawMusicWater(delta) {
    if (!musicPaint) return;
    const playing = el('recommendation-list').querySelector('.ripple-focus.playing,.ripple-orbit.playing');
    const active = !!playing || !!recommendationView?.items.some(item => recommendationView.keyOf(item) === recommendationView.currentKey);
    const progressing = musicTime == null || audio.currentTime > musicTime;
    musicTime = audio.currentTime;
    if (active && (!progressing || audio.readyState < 3)) return;
    const rings = musicRipples.sample(bins,delta,active);
    musicWater.dataset.mode = bins ? 'audio' : 'playback';
    const box = musicWater.getBoundingClientRect(), ratio = Math.min(root.devicePixelRatio || 1,1.5);
    const w = Math.round(box.width*ratio), h = Math.round(box.height*ratio);
    if (musicWater.width !== w || musicWater.height !== h) { musicWater.width=w; musicWater.height=h; }
    musicPaint.setTransform(ratio,0,0,ratio,0,0); musicPaint.clearRect(0,0,box.width,box.height);
    if (!active || !rings.length) return;
    const origin = playing?.getBoundingClientRect();
    const target = origin ? {x:origin.x+origin.width/2-box.x,y:origin.y+origin.height/2-box.y,width:origin.width} : {x:box.width*.52,y:box.height*.64,width:box.width*.46};
    if (!musicOrigin) musicOrigin = target;
    else for (const key of ['x','y','width']) musicOrigin[key] += (target[key]-musicOrigin[key]) * (1-Math.exp(-delta/260));
    const {x,y} = musicOrigin;
    musicPaint.lineCap='round'; musicPaint.lineJoin='round';
    for (const ring of rings) {
      const life=(musicRipples.time-ring.born)/ring.life;
      const radius=musicOrigin.width*.42 + (1-(1-life)**1.5)*Math.min(box.width,box.height)*.48;
      const alpha=Math.sin(Math.PI*life)**1.2 * (1-life*.55)*ring.strength;
      const phase=ring.phase+life*.65;
      const driftX=Math.sin(ring.phase)*life*9, driftY=-life*8;
      // Light catches only sections of the crest; the rest dissolves into the
      // shared pond. No rigid concentric outline, no expanding song controls.
      for (const [start,span] of [[phase*.16,Math.PI*1.12],[phase*.16+Math.PI*1.35,Math.PI*.44]]) {
        const points=waterCurve(radius,phase,start,span,.72+Math.sin(ring.phase)*.035);
        const first=points[0],last=points[points.length-1];
        const shine=musicPaint.createLinearGradient(x+first.x,y+first.y,x+last.x,y+last.y);
        shine.addColorStop(0,'rgba(250,255,231,0)'); shine.addColorStop(.25,`rgba(250,255,231,${alpha*.92})`);
        shine.addColorStop(.65,`rgba(239,250,217,${alpha*.6})`); shine.addColorStop(1,'rgba(250,255,231,0)');
        for (const [offset,color,width] of [[2,`rgba(43,103,84,${alpha*.12})`,3],[0,shine,1.6]]) {
          musicPaint.beginPath();
          points.forEach((p,index)=>musicPaint[index ? 'lineTo' : 'moveTo'](x+p.x+driftX,y+p.y+driftY+offset));
          musicPaint.strokeStyle=color;musicPaint.lineWidth=width;musicPaint.stroke();
        }
      }
    }
  }
  let spectrumContext = null, analyser = null, capture = null, bins = null, spectrumFrame = null, spectrumLast = 0;
  function stopSpectrum() {
    if (spectrumFrame != null) cancelAnimationFrame(spectrumFrame);
    spectrumFrame = null;
    list.querySelectorAll('.leaf-spectrum i').forEach(bar => bar.style.removeProperty('--level'));
    clearMusicWater();
  }
  function drawSpectrum(now) {
    if (audio.paused || document.hidden || reducedMotion.matches) { stopSpectrum(); return; }
    if (now - spectrumLast > 45) {
      const delta = Math.min(100, now - spectrumLast);
      spectrumLast = now;
      if (analyser && bins) analyser.getByteFrequencyData(bins);
      list.querySelectorAll('.playing .leaf-spectrum i').forEach((bar,i) => {
        if (!bins) return;
        const bin = Math.min(bins.length-1, Math.floor(2 * Math.pow(1.22,i)));
        bar.style.setProperty('--level', String(.05 + bins[bin]/255 * .95));
      });
      drawMusicWater(delta);
    }
    spectrumFrame = requestAnimationFrame(drawSpectrum);
  }
  async function startSpectrum() {
    if (audio.paused || document.hidden || reducedMotion.matches) return;
    try {
      const sameOrigin = new URL(audio.currentSrc || audio.src, root.location.href).origin === root.location.origin;
      if (!analyser && sameOrigin) {
        const captureAudio = audio.captureStream || audio.mozCaptureStream;
        if (captureAudio && root.AudioContext) {
          capture = captureAudio.call(audio);
          if (capture.getAudioTracks().length) {
            spectrumContext = new root.AudioContext();
            analyser = spectrumContext.createAnalyser(); analyser.fftSize = 1024; analyser.smoothingTimeConstant=.82;
            spectrumContext.createMediaStreamSource(capture).connect(analyser);
            bins = new Uint8Array(analyser.frequencyBinCount);
          } else { capture.getTracks().forEach(track => track.stop()); capture=null; }
        }
      }
      const context = spectrumContext;
      if (context) await context.resume();
      if (context !== spectrumContext) return;
    } catch { resetSpectrum(); } // A missing capture must never interfere with playback.
    if (spectrumFrame == null && !audio.paused && !document.hidden && !reducedMotion.matches) spectrumFrame=requestAnimationFrame(drawSpectrum);
  }
  function resetSpectrum() {
    stopSpectrum(); capture?.getTracks().forEach(track => track.stop()); capture=null;
    void spectrumContext?.close(); spectrumContext=null; analyser=null; bins=null;
  }
  audio.addEventListener('emptied', resetSpectrum);
  audio.addEventListener('playing', startSpectrum);
  audio.addEventListener('pause', stopSpectrum);
  audio.addEventListener('ended', stopSpectrum);
  reducedMotion.addEventListener('change', () => reducedMotion.matches ? stopSpectrum() : void startSpectrum());
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
    stopSpectrum();
    if (stemFrame != null) cancelAnimationFrame(stemFrame);
    stemFrame = null;
    if (pointerFrame != null) cancelAnimationFrame(pointerFrame);
    pointerFrame=null;
    resetSpectrum();
  });

  drawTree();
  root.MusicTreeUI = {
    filterLibrary(items) { return el('tree-scope').value === 'lyrics' ? items.filter((item) => item.has_local_lyrics ?? !!item.lyrics_url) : items; },
    renderLibrary(view) {
      libraryView = view;
      const changedSong = lastPlayingKey !== view.currentKey;
      lastPlayingKey = view.currentKey;
      const scope = JSON.stringify([view.searchQuery, view.librarySort, el('tree-scope').value]);
      if (scopeVersion !== scope) { clearTimeout(turnTimer); turnTimer = null; wheelRemainder = 0; viewport.classList.remove('is-turning'); }
      scopeVersion = scope;
      model.setItems(view.items, scope);
      if (changedSong) {
        const playingIndex = model.items.findIndex(item => view.keyOf(item) === view.currentKey);
        if (playingIndex >= 0 && (playingIndex < model.start || playingIndex >= model.start + PAGE_SIZE)) {
          clearTimeout(turnTimer); turnTimer = null;
          model.setStart(playingIndex - Math.floor(PAGE_SIZE / 2));
        }
      }
      if (turnTimer == null && paintFrame == null) desiredStart = model.start;
      else desiredStart = Math.min(desiredStart, model.max);
      flowTree(desiredStart);
      el('library-more').hidden = true;
      document.body.dataset.playing = String(!view.paused);
      paintLibrary();
    },
    renderRecommendations(view) {
      recommendationView = view;
      const nextFocus = playbackFocus(view.items, view.keyOf, view.currentKey, lastRecommendationKey, focusId);
      lastRecommendationKey = view.currentKey;
      if (nextFocus !== focusId) { focusId = nextFocus; promoteRecommendation(); }
      else paintRecommendations();
      const item = view.currentTrack || view.items.find((entry) => view.keyOf(entry) === view.currentKey);
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
