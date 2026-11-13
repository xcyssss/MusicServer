// Inspect only the disposable WebView2 instance launched by verify_portable_paths.ps1.
const fs = require('node:fs');
const assert = require('node:assert/strict');
const [port, mode, screenshot] = process.argv.slice(2);
const sleep = ms => new Promise(r => setTimeout(r, ms));
(async () => {
  let target, lastProbe;
  for (let i = 0; i < 80; i++) {
    try {
      const tabs = await (await fetch(`http://127.0.0.1:${port}/json/list`, { signal: AbortSignal.timeout(2000) })).json();
      lastProbe = tabs.map(t => ({ type: t.type, url: t.url }));
      target = tabs.find(t => t.type === 'page' && (mode === 'error' ? t.url.includes('path_error=') : /^http:\/\/127\.0\.0\.1:\d+\/(?:music-tree\.html)?$/.test(t.url)));
      if (target) break;
    } catch (e) { lastProbe = String(e); }
    await sleep(250);
  }
  assert.ok(target, `No ${mode} desktop WebView found: ${JSON.stringify(lastProbe)}`);
  const ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject; });
  let sequence = 0;
  const pending = new Map();
  ws.onmessage = event => { const m = JSON.parse(event.data); if (pending.has(m.id)) { const { resolve, reject, timer } = pending.get(m.id); clearTimeout(timer); pending.delete(m.id); m.error ? reject(new Error(JSON.stringify(m.error))) : resolve(m.result); } };
  function call(method, params = {}) {
    return new Promise((resolve, reject) => {
      const id = ++sequence;
      const timer = setTimeout(() => { pending.delete(id); reject(new Error(`CDP timeout: ${method}`)); }, 8000);
      pending.set(id, { resolve, reject, timer }); ws.send(JSON.stringify({ id, method, params }));
    });
  }
  try {
    const result = await call('Runtime.evaluate', { expression: 'JSON.stringify({title:document.title,text:document.body.innerText,url:location.href,width:innerWidth,height:innerHeight})', returnByValue: true });
    const page = JSON.parse(result.result.value);
    if (mode === 'error') {
      assert.match(page.text, /请重新定位数据目录/);
      assert.match(page.text, /本次启动已停止/);
      assert.doesNotMatch(page.text, /打开日志文件夹/);
    } else { assert.match(page.url, /^http:\/\/127\.0\.0\.1:\d+\//); assert.match(page.text, /音乐/); }
    const shot = await call('Page.captureScreenshot', { format: 'png' });
    fs.writeFileSync(screenshot, Buffer.from(shot.data, 'base64'));
    console.log(JSON.stringify({ mode, title: page.title, width: page.width, height: page.height, screenshot }));
  } finally { ws.close(); }
})().catch(e => { console.error(e); process.exitCode = 1; });
