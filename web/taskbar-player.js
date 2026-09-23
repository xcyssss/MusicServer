(() => {
  'use strict';
  const invoke = window.__TAURI__.core.invoke, listen = window.__TAURI__.event.listen;
  const $ = id => document.getElementById(id);
  let snapshot = { key: '' }, revision = 0;
  function render(state) {
    snapshot = state;
    $('dock-title').textContent = state.title || 'MusicServer';
    $('dock-artist').textContent = state.artist || '';
    $('dock-lyric').textContent = state.lyric || '让音乐，从一片叶子开始';
    $('dock-text').title = `${state.title || 'MusicServer'}\n${state.lyric || ''}\n拖动调整位置 · 双击显示主窗口`;
    $('toggle').querySelector('path').setAttribute('d', state.playing ? 'M8 5v14M16 5v14' : 'm8 5 11 7-11 7Z');
    $('toggle').setAttribute('aria-label', state.playing ? '暂停' : '播放');
    for (const action of ['previous', 'toggle', 'next']) $(action).disabled = !state.can_play;
    $('like').disabled = !state.can_like;
    $('like').setAttribute('aria-pressed', String(state.liked));
    $('like').setAttribute('aria-label', state.liked ? '取消喜欢当前歌曲' : '喜欢当前歌曲并下载');
    $('like').title = state.can_like ? '喜欢后自动下载' : '当前本地歌曲没有可收藏的推荐记录';
  }
  async function action(name) {
    $('dock-status').textContent = '';
    try { await invoke('desktop_player_action', { action: name, key: snapshot.key }); }
    catch { $('dock-status').textContent = '控制未送达，请重试或打开主窗口'; }
  }
  for (const name of ['restore','previous','toggle','next','like','hide']) $(name).addEventListener('click', () => action(name));
  $('dock-text').addEventListener('dblclick', () => action('restore'));
  let last = null, pending = 0, moving = false;
  async function shift() {
    if (moving || !pending) return;
    const delta = pending; pending = 0; moving = true;
    try { await invoke('shift_desktop_player', { delta }); } catch {}
    finally { moving = false; if (pending) void shift(); }
  }
  $('dock-text').addEventListener('pointerdown', e => { if(e.button !== 0)return; last=e.screenX; e.currentTarget.setPointerCapture(e.pointerId); });
  $('dock-text').addEventListener('pointermove', e => { if(last === null)return; pending += (e.screenX-last)/Math.max(100,screen.availWidth-552); last=e.screenX; void shift(); });
  for(const event of ['pointerup','pointercancel','lostpointercapture']) $('dock-text').addEventListener(event, () => { last=null; });
  // Listen before reading initial state so an older snapshot cannot overwrite a
  // newer track that arrived while the invoke request was in flight.
  listen('desktop-player-state', ({payload}) => { revision++; render(payload); }).then(async unlisten => {
    window.addEventListener('pagehide', unlisten, {once:true});
    const before = revision;
    const state = await invoke('desktop_player_snapshot');
    if(before === revision) render(state);
  }).catch(() => { $('dock-status').textContent='播放器连接失败，请重新开启任务栏歌词'; });
})();
