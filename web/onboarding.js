/* First-use guide. Persisted preferences and queue outcomes come from the API. */
(function (root) {
  'use strict';
  function downloadStage(item, wanted) {
    const entry = wanted || item?.wanted;
    const state = entry?.state || item?.local_status;
    if (state === 'LOCAL' || state === 'COMPLETED') return 'ready';
    if (['UNAVAILABLE', 'FAILED', 'PAUSED', 'MANUAL_REQUIRED'].includes(state)) return 'attention';
    return item?.liked || entry ? 'pending' : 'none';
  }
  if (typeof module === 'object' && module.exports) { module.exports = { downloadStage }; return; }
  const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (s) => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[s]));
  let bridge, panel, prefs, busy = false, error = '', signature = '', focusBefore;
  let selectedId = '', heardId = '';
  async function save(values) {
    prefs = await bridge.request('/api/onboarding', { method: 'PUT', headers: {'Content-Type':'application/json'}, body: JSON.stringify(values) });
    if ('normalize' in values) bridge.applyDisplayMode(prefs.normalize ? 'canonical' : 'raw');
  }
  function closeLocally() { panel.hidden = true; signature = ''; focusBefore?.focus?.(); }
  function draw() {
    if (!bridge || !panel || !prefs || prefs.dismissed || prefs.phase === 'done') return;
    const view = bridge.view();
    const item = view.items.find((song) => song.track_id === selectedId) || prefs.track || view.current || view.items[0];
    if (view.playing && view.current) heardId = view.current.track_id;
    const current = view.current || item;
    const currentLabel = current ? [current.title, current.artist].filter(Boolean).join(' · ') : '正在准备初遇歌单…';
    const entry = view.wanted.find((job) => job.track_id === item?.track_id) || item?.wanted;
    const stage = downloadStage(item, entry);
    const button = (action, label, disabled = false, primary = false) => `<button type="button" data-guide="${action}" class="${primary ? 'guide-primary' : 'guide-secondary'}" ${busy || disabled ? 'disabled' : ''}>${label}</button>`;
    const phase = prefs.phase;
    const isWelcome = phase === 'welcome';
    const isDownload = phase === 'download';
    const heading = isWelcome ? '让第一片叶子，为你生长。' : isDownload ? (stage === 'ready' ? '喜欢的歌，已经留下。' : '喜欢之后，交给我。') : '听见喜欢，就点一颗心。';
    let content = '';
    if (isWelcome) {
      content = `<p>不用先准备音乐库。右边已经放好一份<strong>初遇歌单</strong>，联网就可以试着听听。你的喜欢和常听，会慢慢成为日推的方向。</p><div class="guide-options"><label><input type="checkbox" data-guide-option="normalize" ${prefs.normalize ? 'checked' : ''}><span>自动整理显示的歌名与歌手<small>只整理界面里的名字，原文件保持原样；识别仍为 Beta。</small></span></label><label><input type="checkbox" data-guide-option="auto_lyrics" ${prefs.auto_lyrics ? 'checked' : ''}><span>自动查找歌词<small>优先找同名歌词文件，再联网匹配；确认不了就说明原因。</small></span></label></div><div class="guide-actions">${button('start','带我听一首 →', !view.items.length, true)}${button('library','我已有音乐文件')}</div>`;
    } else if (!isDownload) {
      content = `<p>点击右侧任意歌曲都能试听。喜欢一首，它会加入后台下载队列；下载成功后，就能在左边的音乐树里找到。</p><div class="guide-song"><span>正在探索</span><strong>${esc(currentLabel)}</strong><small>${esc(view.playbackStatus)}</small></div><div class="guide-actions">${button('like','♡ 喜欢这首，自动下载', !current || heardId !== current.track_id, true)}${button('another','换一首听听', !view.items.length)}</div><p class="guide-footnote">还没听到声音？可以换一首试试。部分在线歌曲会受来源或网络限制。</p>`;
    } else {
      const description = stage === 'ready' ? '现在可以从左侧音乐树播放这首歌。以后点喜欢，也会这样自动收藏并下载。' : stage === 'attention' ? '歌曲已经喜欢，但这次下载没有完成。打开下载动态，可以看到具体原因和可用的重试操作。' : '歌曲已经喜欢，下载仍在后台进行。完成后才会显示为本地歌曲；你可以继续听其他歌。';
      content = `<p>${description}</p><div class="guide-song"><span>${stage === 'ready' ? '已下载' : stage === 'attention' ? '需要留意' : '等待下载结果'}</span><strong>${esc(item?.title || '你喜欢的歌')}</strong><small>${esc(entry ? bridge.explain(entry) : '打开下载动态查看最新状态。')}</small></div><div class="guide-actions">${button('downloads','查看下载动态', false, true)}${button('finish','开始自由探索 →')}</div>`;
    }
    const readiness = !prefs.download_ready ? `<div class="guide-readiness" role="note"><strong>试听可以先开始，自动下载还缺少组件</strong><span>${esc(prefs.missing_components.join('、'))}尚未就绪。可以一键准备，完成后喜欢的歌曲会继续下载。</span><button type="button" data-guide="setup" class="guide-secondary">准备下载环境</button><span></span></div>` : '';
    const html = `<div class="guide-top"><span>初 遇 · MUSICSERVER</span><button type="button" data-guide="dismiss" class="guide-close" aria-label="暂时收起新手引导" ${busy ? 'disabled' : ''}>×</button></div><ol class="guide-steps" aria-label="体验步骤"><li ${isWelcome ? 'aria-current="step"' : ''}>相遇</li><li ${!isWelcome && !isDownload ? 'aria-current="step"' : ''}>听见</li><li ${isDownload ? 'aria-current="step"' : ''}>留下</li></ol><h2 id="guide-title">${heading}</h2>${content}${readiness}<p class="guide-error" role="status">${esc(error || (busy ? '正在处理…' : ''))}</p><footer>随时收起，之后可从「设置 · 新手引导」继续。</footer>`;
    if (signature !== html) {
      const focused = panel.contains(document.activeElement) ? document.activeElement.dataset.guide : null;
      signature = html; panel.innerHTML = html;
      if (focused) panel.querySelector(`[data-guide="${focused}"]`)?.focus();
    }
    panel.hidden = false;
  }
  async function act(action) {
    if (busy) return;
    busy = true; error = ''; draw();
    try {
      if (action === 'setup') { window.MusicServerCare?.open(); }
      else if (action === 'dismiss' || action === 'finish') {
        await save({ dismissed: true, ...(action === 'finish' ? { phase: 'done' } : {}) }); closeLocally();
      } else if (action === 'library') {
        await save({ normalize: prefs.normalize, auto_lyrics: prefs.auto_lyrics, dismissed: true });
        closeLocally(); bridge.settings();
      } else if (action === 'downloads') {
        bridge.downloads();
      } else if (action === 'start' || action === 'another') {
        const view = bridge.view();
        const index = action === 'start' ? 0 : (view.items.findIndex((v) => v.track_id === view.current?.track_id) + 1) % view.items.length;
        const item = view.items[index];
        if (!item) throw new Error('推荐仍在准备，请稍后重试。');
        await save({ phase: 'listen', track_id: item.track_id, normalize: prefs.normalize, auto_lyrics: prefs.auto_lyrics, dismissed: false });
        selectedId = item.track_id;
        // Loading an unavailable source must not lock "another" or "dismiss".
        // The shared player reports playback failures; this guide observes playing.
        void bridge.play(item);
      } else if (action === 'like') {
        const item = bridge.view().current;
        if (!item || heardId !== item.track_id) throw new Error('先听到一首歌，再决定是否喜欢。');
        selectedId = item.track_id;
        if (!item.liked) await bridge.like(item);
        if (!item.liked) throw new Error('喜欢尚未保存，请重试。');
        await save({ phase: 'download', track_id: item.track_id, dismissed: false });
        await bridge.refreshWanted();
      }
    } catch (e) { error = e.message || '暂时无法连接服务，请稍后重试。'; }
    finally { busy = false; draw(); }
  }
  root.MusicServerGuide = {
    update: draw,
    async connect(api) {
      bridge = api;
      panel = document.createElement('aside'); panel.id = 'onboarding-guide'; panel.className = 'onboarding-guide'; panel.hidden = true;
      panel.setAttribute('aria-labelledby', 'guide-title'); document.body.append(panel);
      panel.addEventListener('click', (event) => { const button = event.target.closest('[data-guide]'); if (button) void act(button.dataset.guide); });
      panel.addEventListener('change', (event) => { const name = event.target.dataset.guideOption; if (name && prefs) prefs[name] = event.target.checked; });
      panel.addEventListener('keydown', (event) => { if (event.key === 'Escape') { event.stopPropagation(); void act('dismiss'); } });
      const open = document.getElementById('onboarding-open');
      open?.addEventListener('click', async () => {
        focusBefore = open; error = '';
        try {
          prefs = await bridge.request('/api/onboarding', { method: 'POST', headers: {'Content-Type':'application/json'}, body: '{}' });
          await save({ dismissed: false, phase: 'welcome' });
          bridge.closeSettings(); await bridge.refreshRecommendations(); draw(); panel.querySelector('button')?.focus();
        } catch { bridge.toast('引导暂时无法连接服务，请稍后重试。'); }
      });
      try {
        prefs = await bridge.request('/api/onboarding', { method: 'POST', headers: {'Content-Type':'application/json'}, body: '{}' });
        selectedId = prefs.track?.track_id || '';
        await bridge.refreshRecommendations(); draw();
      } catch { bridge.toast('初遇歌单暂时未能准备好，可从设置重新打开新手引导。'); }
    },
  };
})(globalThis);
