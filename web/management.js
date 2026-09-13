/* Desktop care: bounded server jobs and explicit offline restore. */
(function () {
  'use strict';
  const settings = document.querySelector('#settings-panel .settings-content');
  if (!settings) return;
  const section = document.createElement('section');
  section.className = 'settings-group app-care';
  section.innerHTML = `<h3>下载与数据照料</h3><p class="settings-hint">喜欢会自动下载。首次使用，先让我准备下载和音频校验组件。</p><div data-care-components></div><div class="settings-actions"><button class="secondary-button" data-care="components">准备下载环境</button><button class="text-button" data-care="health">检查组件</button></div><p class="settings-hint">约 123 MB · 从 yt-dlp 和 FFmpeg 发布方下载，校验通过后使用，无需管理员权限。</p><p data-care-status role="status" aria-live="polite"></p><progress data-care-progress max="100" hidden aria-label="当前操作进度"></progress><div class="settings-actions"><button class="secondary-button" data-care="backup">备份我的数据</button><button class="secondary-button" data-care="diagnostics">导出诊断包</button></div><p class="settings-hint">诊断包仅包含组件、队列状态和完整性检查；不含歌名、路径、Cookie、原始日志或歌曲。生成后可以先查看再分享。</p><button class="text-button" data-care="output" hidden>查看生成的文件</button><label for="care-backups">恢复到已有备份</label><select id="care-backups" aria-label="选择数据备份"></select><button class="text-button" data-care="restore">恢复所选备份…</button><p class="settings-hint">备份包含喜欢、听歌记录、推荐、队列与设置，不包含歌曲和登录凭据。恢复前会再保存当前数据；恢复后重新启动。</p><div data-care-confirm hidden><p>将用所选备份替换当前应用数据和设置，歌曲文件不会移动或删除。</p><button class="secondary-button" data-care="confirm-restore">保存当前数据并恢复</button><button class="text-button" data-care="cancel-restore">取消</button></div>`;
  settings.append(section);
  const find = (s) => section.querySelector(s);
  const messages = { RESTORE_COMPLETE:'数据已恢复，恢复前的数据也已保留为安全备份。', RESTORE_FAILED:'恢复未完成，原数据已保留。请检查备份后再试。', BACKUP_CHECKSUM_MISMATCH:'备份校验未通过，原数据已保留。', COMPLETE:'已完成', 'FETCH_yt-dlp':'正在下载 yt-dlp', FETCH_ffmpeg:'正在下载音频组件', VERIFY_AUDIO:'正在验证版本和音频转换', COMPONENT_CHECKSUM_MISMATCH:'文件校验未通过，请重试。不会使用未验证的文件。', INTERRUPTED_OR_TIMEOUT:'上次操作中断或超时，可以重新开始。', WORKER_FAILED:'操作没有完成，可以重新尝试或导出诊断。', WebException:'网络连接失败，请检查网络后重试。', COMPONENT_AUDIO_PROBE_FAILED:'音频组件未通过实际转换测试，请重新准备。', SERVICES_STILL_RUNNING:'另一个 MusicServer 仍在使用数据，请关闭后重试。' };
  const labels = { components:'准备下载环境', health:'检查组件', backup:'备份数据', diagnostics:'导出诊断包' };
  let state, requesting = false, poll, active = false;
  async function request(path, options) {
    const controller = new AbortController(); const timer = setTimeout(() => controller.abort(), 12000);
    try { const response = await fetch(path, { ...options, signal: controller.signal }); const value = await response.json(); if (!response.ok) throw new Error(value.error || '服务暂时不可用'); return value; } finally { clearTimeout(timer); }
  }
  function draw() {
    const box = find('[data-care-components]'); box.replaceChildren();
    for (const item of state.components) { const line = document.createElement('span'); line.className='care-component'; line.textContent = `${item.present ? '✓' : '○'} ${item.name}${item.managed ? ' · 应用管理' : ''}`; box.append(line); }
    const restoreNote = state.restore_result ? `${messages[state.restore_result] || state.restore_result}\n` : '';
    const job = state.jobs[0]; active = job?.state === 'RUNNING';
    find('[data-care-status]').textContent = job ? `${labels[job.operation] || '操作'} · ${active ? `${job.progress}% · ` : ''}${messages[job.message] || (job.state === 'ERROR' ? `未完成（${job.message}），可重试或导出诊断。` : '正在准备…')}` : state.ready ? '组件已找到。可点“检查组件”验证实际音频处理。' : '试听可以先开始，喜欢的歌曲会保留在队列，组件准备好后继续下载。';
    find('[data-care-status]').textContent = restoreNote + find('[data-care-status]').textContent;
    find('[data-care-progress]').hidden = !active; find('[data-care-progress]').value=job?.progress || 0;
    for (const button of section.querySelectorAll('[data-care]')) button.disabled = (active || requesting) && !['output','cancel-restore'].includes(button.dataset.care);
    find('[data-care=output]').hidden = !state.jobs.some((item) => item.state === 'DONE' && item.result_path);
    const select=find('#care-backups'); const previous=select.value;
    select.replaceChildren();
    for (const backup of state.backups) { const option=document.createElement('option'); option.value=backup.id; option.textContent=`${new Date(backup.created_at).toLocaleString()} · ${backup.reason === 'manual' ? '手动备份' : backup.reason === 'before-restore' ? '恢复前的安全备份' : '升级前的安全备份'}`; select.append(option); }
    if (state.backups.some((b) => b.id === previous)) select.value=previous;
    find('[data-care=restore]').disabled=active || !state.backups.length;
  }
  async function refresh() {
    clearTimeout(poll);
    try { state=await request('/api/maintenance'); draw(); } catch { find('[data-care-status]').textContent='暂时无法连接数据服务，请稍后重试。'; }
    if (!document.querySelector('#settings-panel').hidden || active) poll=setTimeout(refresh, active ? 1800 : 6000);
  }
  async function act(action) {
    if (requesting) return;
    const invoke=window.__TAURI__?.core?.invoke;
    if (action==='cancel-restore') { find('[data-care-confirm]').hidden=true; return; }
    if (action==='restore') { find('[data-care-confirm]').hidden=false; find('[data-care=confirm-restore]').focus(); return; }
    requesting=true;
    try {
      if (action==='output') { if (!invoke) throw new Error('请在桌面 APP 内打开文件夹。'); await invoke('open_folder',{path:state.output_dir}); }
      else if (action==='confirm-restore') { if (!invoke) throw new Error('恢复需要桌面 APP。'); find('[data-care-status]').textContent='正在保存当前数据并恢复，请稍候…'; await invoke('restore_backup',{backupId:find('#care-backups').value}); }
      else { await request('/api/maintenance',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({operation:action})}); requesting=false; await refresh(); }
    } catch (error) { find('[data-care-status]').textContent=messages[error.message] || String(error.message || error); }
    finally { requesting=false; }
  }
  section.addEventListener('click',(event) => { const button=event.target.closest('[data-care]'); if (button) void act(button.dataset.care); });
  new MutationObserver(() => { if (!document.querySelector('#settings-panel').hidden) void refresh(); }).observe(document.querySelector('#settings-panel'),{attributes:true,attributeFilter:['hidden']});
  window.MusicServerCare={open() { if (document.querySelector('#settings-panel').hidden) document.querySelector('#settings-toggle').click(); section.scrollIntoView({block:'start',behavior:'smooth'}); void refresh(); }};
})();
