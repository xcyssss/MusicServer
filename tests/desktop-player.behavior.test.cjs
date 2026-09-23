const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const {lyricLine}=require('../web/desktop-bridge.js');
test('taskbar lyrics follow seeks, silence before the first line, and missing lyrics without stale text',()=>{
  const lyrics={available:true,entries:[{time:3,text:'新叶'},{time:8,text:'水光'}]};
  assert.equal(lyricLine(lyrics,8),'水光'); assert.equal(lyricLine(lyrics,4),'新叶');
  assert.match(lyricLine(lyrics,0),/等待/); assert.match(lyricLine({},10),/暂无同步歌词/);
});
function fixture({failSave=false}={}) {
  const elements=new Map(), calls=[],actions=[],listeners={}, audioListeners={};
  const element=id=>{if(!elements.has(id))elements.set(id,{checked:false,disabled:false,hidden:false,textContent:'',addEventListener:(name,fn)=>elements.get(id)[name]=fn});return elements.get(id)};
  const group={querySelector:element};
  let view={key:'song-a',lyric:'第一句'};
  const root={__TAURI__:{core:{invoke:async(name,args)=>{calls.push({name,args})}},event:{listen:async(name,fn)=>{listeners[name]=fn;return()=>{}}}},addEventListener:()=>{}};
  root.document={hidden:true,createElement:()=>group,querySelector:s=>s==='.settings-content'?{prepend:()=>{}}:{addEventListener:(name,fn)=>audioListeners[name]=fn,removeEventListener:()=>{}}};
  vm.runInNewContext(fs.readFileSync(require.resolve('../web/desktop-bridge.js'),'utf8'),root);
  root.MusicServerDesktop.connect({request:async(url,options)=>{if(options&&failSave)throw Error('offline');return {tray_only:false,taskbar_lyrics:true}},view:()=>view,action:a=>actions.push(a),toast:()=>{}});
  return {root,calls,actions,listeners,audioListeners,element,setView:v=>view=v};
}
const settle=()=>new Promise(resolve=>setImmediate(resolve));
test('hidden main player publishes changed lyrics once and rejects actions for an obsolete song',async()=>{
  const f=fixture();await settle();
  f.calls.length=0;
  f.setView({key:'song-b',lyric:'第二句'});
  await f.audioListeners.timeupdate();await settle();
  await f.audioListeners.timeupdate();await settle();
  assert.equal(f.calls.filter(c=>c.name==='publish_desktop_player').length,1);
  f.listeners['desktop-player-action']({payload:{action:'like',key:'song-a'}});await settle();assert.equal(f.actions.length,0);
  f.listeners['desktop-player-action']({payload:{action:'like',key:'song-b'}});assert.deepEqual(f.actions,['like']);
});
test('failed settings save restores the native mode and checkbox instead of hiding the app permanently',async()=>{
  const f=fixture({failSave:true});await settle();f.calls.length=0;
  const tray=f.element('#desktop-tray-only');tray.checked=true;await tray.change();await settle();
  const applied=f.calls.filter(c=>c.name==='apply_desktop_preferences').map(c=>c.args.preferences.tray_only);
  assert.deepEqual(applied,[true,false]);assert.equal(tray.checked,false);assert.match(f.element('#desktop-settings-status').textContent,/未能保存/);
});
