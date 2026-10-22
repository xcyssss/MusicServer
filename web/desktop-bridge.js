(function (root) {
  'use strict';
  function watchWindowVisibility(nativeWindow, onChange, clock = root) {
    let visible = true, closed = false, pending = false, refreshAgain = false, timer = null;
    const unlisteners = [];
    async function refresh() {
      if (closed) return;
      if (pending) { refreshAgain = true; return; }
      pending = true;
      try {
        const [minimized, shown] = await Promise.all([nativeWindow.isMinimized(), nativeWindow.isVisible()]);
        if (!closed && visible !== (!minimized && shown)) {
          visible = !minimized && shown;
          onChange(visible);
        }
      } catch { /* Browsers and unavailable native reads keep their last usable state. */ }
      finally {
        pending = false;
        if (refreshAgain && !closed) { refreshAgain = false; void refresh(); }
      }
    }
    function poll() {
      timer = clock.setTimeout(() => { timer = null; void refresh(); if (!closed) poll(); }, 2000);
    }
    for (const event of ['onResized', 'onFocusChanged']) {
      if (typeof nativeWindow[event] !== 'function') continue;
      Promise.resolve(nativeWindow[event](refresh)).then(unlisten => {
        if (closed) unlisten(); else unlisteners.push(unlisten);
      }).catch(() => {});
    }
    // WebView2 may keep document.visibilityState visible for a minimized window.
    void refresh(); poll();
    return { isVisible: () => visible, dispose() {
      closed = true;
      if (timer != null) clock.clearTimeout(timer);
      timer = null; unlisteners.splice(0).forEach(unlisten => unlisten());
    } };
  }
  function lyricLine(lyrics, time) {
    const entries = lyrics?.entries || [];
    let active = -1;
    for (let i = 0; i < entries.length && entries[i].time <= time; i++) active = i;
    if (active >= 0) return entries[active].text;
    if (entries.length) return '♪ 等待第一句';
    return lyrics?.available ? '♪ 纯文本歌词 · 在主窗口查看' : '♪ 暂无同步歌词';
  }
  function taskbarError(error) {
    const messages = {
      TASKBAR_NO_SPACE: '任务栏空间不足，已尝试自动缩窄。请减少任务栏工具栏或图标占用后重试。',
      TASKBAR_LAYOUT_UNSUPPORTED: '当前任务栏结构不支持内嵌歌词（目前支持 Windows 10 标准横向任务栏）。',
      TASKBAR_VERTICAL_UNSUPPORTED: '竖向任务栏暂不支持歌词内嵌，请将任务栏放到屏幕顶部或底部后重试。',
      TASKBAR_DPI_INCOMPATIBLE: 'APP 与任务栏的缩放模式不一致，请退出并重新打开 APP 后重试。',
      TASKBAR_ALREADY_IN_USE: '另一份 MusicServer 已占用任务栏歌词，请先关闭那一份的歌词栏。',
      TASKBAR_NOT_READY: 'Windows 任务栏尚未就绪，请稍后重试。',
      TASKBAR_BOUNDS_UNAVAILABLE: '暂时无法读取任务栏位置，请稍后重试。',
      TASKBAR_ATTACH_FAILED: 'Windows 未能将歌词窗口嵌入任务栏，请重新打开 APP 后重试。',
      TASKBAR_POSITION_FAILED: 'Windows 未能调整任务栏位置，请稍后重试。',
      DOCK_MISSING: '歌词窗口正在恢复，请稍后重试。'
    };
    const code = String(error).match(/TASKBAR_[A-Z_]+|DOCK_MISSING/)?.[0];
    return code ? messages[code] || '任务栏歌词暂时无法启用，请稍后重试。' : '';
  }
  function taskbarStatus(state) {
    if (state?.error) return `${taskbarError(state.error)} 已保留开启设置，任务栏恢复后会自动重试。`;
    if (state?.enabled && state.width < state.requested_width) return `任务栏歌词已自动缩窄为 ${state.width} px；空间恢复后会使用设定宽度。`;
    return '已保存，立即生效。关闭主窗口仍会退出软件。';
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
      <label class="settings-option"><input id="desktop-taskbar-lyrics" type="checkbox" disabled /><span class="settings-option-body"><strong>任务栏歌词</strong><small>歌词内嵌在任务栏，移入鼠标显示播放控制；拖动文字切换左右位置，双击回到主窗口。空间不足时自动缩窄。</small></span></label>
      <label class="settings-option"><span>期望宽度 <output id="desktop-width-value">420</output> px</span><input id="desktop-width" type="range" min="360" max="800" step="20" value="420" aria-label="任务栏歌词宽度" disabled /></label>
      <div class="settings-actions"><button id="desktop-hide-now" class="secondary-button" type="button">现在收起到托盘</button><button id="desktop-retry" class="text-button" type="button" hidden>重试</button></div>
      <p id="desktop-settings-status" class="settings-hint" role="status">正在读取桌面设置…</p>`;
    container.prepend(group);
    const tray = group.querySelector('#desktop-tray-only');
    const dock = group.querySelector('#desktop-taskbar-lyrics');
    const status = group.querySelector('#desktop-settings-status');
    const width = group.querySelector('#desktop-width');
    const widthValue = group.querySelector('#desktop-width-value');
    const retry = group.querySelector('#desktop-retry');
    let preferences = { tray_only: false, taskbar_lyrics: false, taskbar_width: 420 }, ready = false, saving = false;
    let writes = Promise.resolve(), sent = '', sending = false, dirty = false;
    const unlisteners = [];
    function controls(busy = false, shown = preferences) {
      tray.checked = shown.tray_only; dock.checked = shown.taskbar_lyrics;
      tray.disabled = dock.disabled = width.disabled = busy || !ready;
      width.value = shown.taskbar_width; widthValue.textContent = shown.taskbar_width;
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
        saving = true;
        controls(true, next);
        try {
          const placement = await invoke('apply_desktop_preferences', { preferences: next });
          await host.request('/api/settings/desktop', { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(next) });
          preferences = next; sent = ''; void publish();
          status.textContent = taskbarStatus(placement);
        } catch (error) {
          await invoke('apply_desktop_preferences', { preferences: previous }).catch(() => {});
          status.textContent = taskbarError(error) || '设置未能保存，请重试。';
          host.toast(status.textContent);
        } finally { saving = false; controls(); }
      });
      return writes;
    }
    async function load() {
      retry.hidden = true;
      try {
        const data = await host.request('/api/settings/desktop');
        preferences = { tray_only: data.tray_only === true, taskbar_lyrics: data.taskbar_lyrics === true, taskbar_width: Number.isInteger(data.taskbar_width) ? data.taskbar_width : 420 };
        ready = true; controls(true);
        try {
          const placement = await invoke('apply_desktop_preferences', { preferences });
          status.textContent = preferences.taskbar_lyrics ? taskbarStatus(placement) : '普通最小化保留任务栏入口，也可选择只留在托盘。';
        } catch (error) {
          status.textContent = taskbarError(error) ? taskbarStatus({ error: String(error) }) : '桌面窗口设置暂未生效，请重试。';
          retry.hidden = false;
        } finally { controls(); }
        void publish();
      } catch { status.textContent = '桌面设置暂时无法读取，请重试。'; retry.hidden = false; }
    }
    width.addEventListener('input', () => { widthValue.textContent = width.value; });
    width.addEventListener('change', () => save({ taskbar_width: Number(width.value) }));
    tray.addEventListener('change', () => save({ tray_only: tray.checked }));
    dock.addEventListener('change', () => save({ taskbar_lyrics: dock.checked }));
    retry.addEventListener('click', load);
    listen('desktop-player-host', ({ payload }) => {
      if (!ready || saving || !preferences.taskbar_lyrics || !payload.enabled) return;
      status.textContent = taskbarStatus(payload);
      retry.hidden = !payload.error;
    }).then(fn => unlisteners.push(fn)).catch(() => {});
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
  let visibility = null;
  const api = { connect, lyricLine, taskbarError, taskbarStatus, watchWindowVisibility, isVisible: () => visibility?.isVisible() !== false };
  if (typeof module === 'object' && module.exports) module.exports = api;
  else {
    root.MusicServerDesktop = api;
    const currentWindow = root.__TAURI__?.window?.getCurrentWindow;
    if (currentWindow) {
      try {
        visibility = watchWindowVisibility(currentWindow(), visible => {
          document.body.classList.toggle('water-paused', document.hidden || !visible);
          document.dispatchEvent(new CustomEvent('musicserver-desktop-visibility', { detail: { visible } }));
        });
        root.addEventListener('pagehide', () => visibility.dispose(), { once: true });
      } catch { /* The browser UI works without native window APIs. */ }
    }
  }
})(globalThis);
