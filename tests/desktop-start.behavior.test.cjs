const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const html = fs.readFileSync(path.join(__dirname, '../web/desktop-start.html'), 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
function render(search) {
  const nodes = new Map();
  const node = () => ({ textContent: '', style: {}, hidden: true, addEventListener() {}, append(item) { this.children.push(item); }, children: [] });
  const document = { title: '', hidden: false, body: { classList: { toggle() {} } }, addEventListener() {},
    querySelector(key) { if (!nodes.has(key)) nodes.set(key, node()); return nodes.get(key); }, createElement: node };
  vm.runInNewContext(script, { document, location: { search }, URLSearchParams });
  return { document, nodes };
}
test('missing data directory gives a readable recovery message without creating a log folder action', () => {
  const message = '找不到原数据：E:\\音乐 <原目录>。请重新定位。';
  const { document, nodes } = render('?failed=1&path_error=' + encodeURIComponent(message));
  assert.match(document.title, /数据目录/);
  assert.equal(nodes.get('#message').textContent, message);
  assert.equal(nodes.get('#retry').hidden, false);
  assert.match(nodes.get('#hint').textContent, /恢复原目录/);
  assert.equal(nodes.has('main'), false);
});
test('ordinary service startup failure retains retry and logs', () => {
  const { nodes } = render('?failed=1');
  assert.equal(nodes.get('#retry').hidden, false);
  assert.match(nodes.get('#message').textContent, /本地服务/);
  assert.equal(nodes.get('main').children[0].textContent, '打开日志文件夹');
});
