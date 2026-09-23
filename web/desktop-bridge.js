(function (root) {
  'use strict';
  function lyricLine(lyrics, time) {
    const entries = lyrics?.entries || [];
    let active = -1;
    for (let i = 0; i < entries.length && entries[i].time <= time; i++) active = i;
    if (active >= 0) return entries[active].text;
    if (entries.length) return '♪ 等待第一句';
    return lyrics?.available ? '♪ 纯文本歌词 · 在主窗口查看' : '♪ 暂无同步歌词';
  }
  function connect(host) {
    const invoke = root.__TAURI__?.core?.invoke;
    const listen = root.__TAURI__?.event?.listen;
    if (!invoke || !listen) return;
    const container = document.querySelector('.settings-content');
    if (!container) return;
    const group = document.createElement('section');
    group.className = 'settings-group desktop-settings';
    group.innerHTML = `<label>窗口与任务栏</label>
      <label class="settings-option"><input id="desktop-tray-only" type="checkbox" disabled /><span class="settings-option-body"><strong>仅最小化到托盘</strong><small>最小化后从任务栏收起，单击托盘图标恢复。</small></span></label>
      <label class="settings-option"><input id="desktop-taskbar-lyrics" type="checkbox" disabled /><span class="settings-option-body"><strong>任务栏歌词</strong><small>贴在任务栏上沿；拖动文字区调整位置，双击回到主窗口。</small></span></label>
      <div class="settings-actions"><button id="desktop-hide-now" class="secondary-button" type="button">现在收起到托盘</button><button id="desktop-retry" class="text-button" type="button" hidden>重试</button></div>
      <p id="desktop-settings-status" class="settings-hint" role="status">正在读取桌面设置…</p>`;
    container.prepend(group);
    const tray = group.querySelector('#desktop-tray-only');
    const dock = group.querySelector('#desktop-taskbar-lyrics');
    const status = group.querySelector('#desktop-settings-status');
    const retry = group.querySelector('#desktop-retry');
    let preferences = { tray_only: false, taskbar_lyrics: false }, ready = false;
    let writes = Promise.resolve(), sent = '', sending = false, dirty = false;
    const unlisteners = [];
    function controls(busy = false, shown = preferences) {
      tray.checked = shown.tray_only; dock.checked = shown.taskbar_lyrics;
      tray.disabled = dock.disabled = busy || !ready;
    }
    async function publish() {
      if (!ready || !preferences.taskbar_lyrics) return;
      if (sending) { dirty = true; return; }
      const snapshot = host.view();
      const signature = JSON.stringify(snapshot);
      if (sent === signature) return;
      sending = true;
      try { await invoke('publish_desktop_player', { snapshot }); sent = signature; }
      catch { sent = ''; }
      finally { sending = false; if (dirty) { dirty = false; void publish(); } }
    }
    function save(change) {
      writes = writes.then(async () => {
        if (!ready) return;
        const previous = preferences, next = { ...preferences, ...change };
        controls(true, next);
        try {
          await invoke('apply_desktop_preferences', { preferences: next });
          await host.request('/api/settings/desktop', { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(next) });
          preferences = next; sent = ''; void publish();
          status.textContent = '已保存，立即生效。关闭主窗口仍会退出软件。';
        } catch {
          await invoke('apply_desktop_preferences', { preferences: previous }).catch(() => {});
          status.textContent = '设置未能保存，请重试。';
          host.toast(status.textContent);
        } finally { controls(); }
      });
      return writes;
    }
    async function load() {
      retry.hidden = true;
      try {
        const data = await host.request('/api/settings/desktop');
        preferences = { tray_only: data.tray_only === true, taskbar_lyrics: data.taskbar_lyrics === true };
        await invoke('apply_desktop_preferences', { preferences });
        ready = true; controls(); void publish();
        status.textContent = '普通最小化保留任务栏入口，也可选择只留在托盘。';
      } catch { status.textContent = '桌面设置暂时无法读取，请重试。'; retry.hidden = false; }
    }
    tray.addEventListener('change', () => save({ tray_only: tray.checked }));
    dock.addEventListener('change', () => save({ taskbar_lyrics: dock.checked }));
    retry.addEventListener('click', load);
    group.querySelector('#desktop-hide-now').addEventListener('click', () => invoke('minimize_to_tray').catch(() => host.toast('托盘暂不可用，请使用普通最小化。')));
    listen('desktop-player-action', ({ payload }) => {
      if (payload.action === 'hide') return save({ taskbar_lyrics: false });
      if (payload.action === 'toggle-dock') return save({ taskbar_lyrics: !preferences.taskbar_lyrics });
      if (payload.key !== host.view().key) { sent = ''; return publish(); }
      host.action(payload.action);
      void publish();
    }).then(fn => unlisteners.push(fn)).catch(() => host.toast('任务栏控制连接失败，请重新启动软件。'));
    const audio = document.querySelector('#audio-player');
    const events = ['timeupdate', 'play', 'pause', 'seeked', 'loadedmetadata', 'emptied'];
    events.forEach(event => audio.addEventListener(event, publish));
    // The audio element remains the only playback clock, including when hidden.
    root.MusicServerDesktop.refresh = publish;
    root.addEventListener('pagehide', () => {
      unlisteners.forEach(fn => fn()); events.forEach(event => audio.removeEventListener(event, publish));
    }, { once: true });
    void load();
  }
  const api = { connect, lyricLine };
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.MusicServerDesktop = api;
})(globalThis);
