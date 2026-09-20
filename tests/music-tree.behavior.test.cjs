const test = require('node:test');
const assert = require('node:assert/strict');
const { LeafWindow, orbitItems, nextRecommendationIndex, treeGeometry, playbackFocus, MusicRipples, waterCurve } = require('../web/music-tree-ui.js');
const tracks = Array.from({ length: 30 }, (_, i) => ({ id: `library-${i}`, track_id: `track-${i}` }));
const { pondLeaf, LEAF_COUNT } = require('../web/pond-water.js');

test('pond leaves sink continuously and recycle only while invisible', () => {
  assert.ok(LEAF_COUNT <= 24);
  const speeds = new Set();
  for (let i = 0; i < LEAF_COUNT; i++) {
    const a = pondLeaf(i, 4000, 1440, 900), b = pondLeaf(i, 4042, 1440, 900);
    speeds.add((b.y - a.y).toFixed(4));
    assert.ok(b.y > a.y && b.y - a.y < 2);
    for (let time = 0; time < 110000; time += 42) {
      const before = pondLeaf(i, time, 960, 640), after = pondLeaf(i, time + 42, 960, 640);
      assert.ok(before.alpha >= 0 && before.alpha < .5);
      if (after.y < before.y) assert.ok(before.alpha < .01 && after.alpha < .01, 'visible leaf teleported');
    }
  }
  assert.ok(speeds.size > 3, 'leaves should not descend as one sheet');
});

test('the pond stops its shared animation clock when hidden or reduced and resumes without accumulating callbacks', () => {
  const vm = require('node:vm'), fs = require('node:fs');
  const callbacks = new Map(), events = {}, preferenceEvents = {};
  let serial = 0, paintCount = 0, now = 0;
  const gradient = {addColorStop(){}};
  const context = new Proxy({}, {get:(_,name) => name.startsWith('create') ? () => gradient : () => {paintCount++;}, set:()=>true});
  const canvas = {getContext:()=>context, parentElement:{appendChild(){}}};
  const preference = {matches:false, addEventListener:(type,fn)=>preferenceEvents[type]=fn};
  const doc = {hidden:false, getElementById:()=>canvas, createElement:()=>({getContext:()=>context,setAttribute(){}}),addEventListener:(type,fn)=>events[type]=fn};
  const sandbox = {document:doc, matchMedia:()=>preference, Path2D:class {}, innerWidth:960,innerHeight:640,performance:{now:()=>now},
    requestAnimationFrame:fn=>{callbacks.set(++serial,fn);return serial;},cancelAnimationFrame:id=>callbacks.delete(id),addEventListener:(type,fn)=>events[type]=fn};
  vm.runInNewContext(fs.readFileSync(require.resolve('../web/pond-water.js'),'utf8'),sandbox);
  assert.equal(callbacks.size,1);
  const tick=()=>{now+=50;const [id,fn]=callbacks.entries().next().value;callbacks.delete(id);fn(now);};
  tick(); assert.equal(callbacks.size,1);
  doc.hidden=true;events.visibilitychange();assert.equal(callbacks.size,0);
  const stopped=paintCount;now+=60000;assert.equal(paintCount,stopped);
  doc.hidden=false;events.visibilitychange();events.visibilitychange();assert.equal(callbacks.size,1);
  preference.matches=true;preferenceEvents.change();assert.equal(callbacks.size,0);
  events.resize();assert.equal(callbacks.size,0);
  preference.matches=false;preferenceEvents.change();assert.equal(callbacks.size,1);
  events.pagehide();assert.equal(callbacks.size,0);
});

test('twenty daily songs are browsed once before any song is repeated', () => {
  const daily = tracks.slice(0, 20), seen = new Set();
  let index = 0;
  for (let page = 0; page < 3; page++) {
    const group = orbitItems(daily, daily[index].track_id);
    for (const song of [group.focus, ...group.orbit]) {
      assert.ok(!seen.has(song.track_id), `repeated before finishing the day: ${song.track_id}`);
      seen.add(song.track_id);
    }
    index = nextRecommendationIndex(index, daily.length, 1);
  }
  assert.equal(seen.size, 20);
  assert.equal(index, 0);
});

test('promoting a daily song swaps focus inside its batch instead of repopulating the other songs', () => {
  const ids = group => [group.focus, ...group.orbit].map(x => x.track_id).sort();
  assert.deepEqual(ids(orbitItems(tracks, 'track-0')), ids(orbitItems(tracks, 'track-4')));
  assert.equal(nextRecommendationIndex(4, 30, 1), 7);
});

test('music water follows audio energy, stays bounded and clears when playback stops', () => {
  const water=new MusicRipples(), silence=new Uint8Array(512), loud=new Uint8Array(512).fill(190);
  for(let i=0;i<80;i++) water.sample(silence,50,true);
  assert.equal(water.rings.length,0);
  water.sample(loud,50,true); assert.equal(water.rings.length,1);
  const strength=water.rings[0].strength;
  for(let i=0;i<200;i++) { water.sample(i%20<5?loud:silence,50,true); assert.ok(water.rings.length<=5); }
  water.sample(silence,50,false); assert.equal(water.rings.length,0);
  water.sample(new Uint8Array(512).fill(25),50,true);
  assert.ok(water.rings[0].strength<strength);
  for(let i=0;i<80;i++) water.sample(silence,50,true);
  assert.equal(water.rings.length,0);
  water.sample(null,50,true); assert.equal(water.rings.length,1, 'uncapturable streams have a quiet playback ripple');
  water.sample(null,50,false); assert.equal(water.rings.length,0);
});

test('water fronts have continuous bounded curvature and successive pulses do not repeat the same phase', () => {
  const points=waterCurve(100,.8);
  assert.ok(Math.hypot(points[0].x-points.at(-1).x,points[0].y-points.at(-1).y)<1e-8);
  const radii=points.map(p=>Math.hypot(p.x,p.y/.7));
  assert.ok(Math.max(...radii)-Math.min(...radii)>5);
  assert.ok(radii.every(r=>r>92 && r<108));
  const shifted=waterCurve(100,.801);
  assert.ok(points.every((p,i)=>Math.hypot(p.x-shifted[i].x,p.y-shifted[i].y)<.02));
  const water=new MusicRipples();
  for(let i=0;i<55;i++)water.sample(new Uint8Array(512).fill(160),50,true);
  assert.ok(water.rings.length>=2);
  assert.equal(new Set(water.rings.map(r=>r.phase)).size,water.rings.length);
});

test('the viewport holds seven songs, clamps at either end and keeps the final seven reachable', () => {
  const view = new LeafWindow(); view.setItems(tracks);
  assert.deepEqual(view.visible.map(x => x.id), tracks.slice(0, 7).map(x => x.id));
  view.move(100);
  assert.equal(view.start, 23);
  assert.deepEqual(view.visible, tracks.slice(23));
  view.move(-100); assert.equal(view.start, 0);
  view.atRatio(.5); assert.equal(view.start, 12);
  view.atRatio(1); assert.equal(view.start, 23);
});

test('group navigation wraps only on an explicit forward group action', () => {
  const view = new LeafWindow(); view.setItems(tracks);
  view.group(1); assert.equal(view.start, 7);
  view.setStart(23); view.move(1); assert.equal(view.start, 23);
  view.group(1); assert.equal(view.start, 0);
  view.group(-1); assert.equal(view.start, 0);
});

test('refresh preserves the visible anchor while scope or search changes reset the viewport', () => {
  const view = new LeafWindow(); view.setItems(tracks, 'all'); view.setStart(10);
  view.setItems([{ id: 'new' }, ...tracks], 'all');
  assert.equal(view.visible[0].id, 'library-10');
  view.setItems(tracks.slice(3, 5), 'search:three');
  assert.equal(view.start, 0); assert.equal(view.visible.length, 2);
  view.setItems([], 'empty'); assert.equal(view.start, 0); assert.equal(view.max, 0);
});

test('recommendation ripples never duplicate the focus, including short and refreshed days', () => {
  assert.deepEqual(orbitItems([], null), { focus: null, orbit: [], index: -1 });
  const one = orbitItems(tracks.slice(0, 1), null); assert.equal(one.orbit.length, 0);
  const two = orbitItems(tracks.slice(0, 2), 'track-1'); assert.equal(two.focus.track_id, 'track-1'); assert.equal(two.orbit[0].track_id, 'track-0');
  const many = orbitItems(tracks, 'track-29');
  assert.equal(many.orbit.length, 1);
  assert.equal(new Set([many.focus, ...many.orbit].map(x => x.track_id)).size, 2);
  assert.equal(orbitItems(tracks.slice(0, 3), 'removed').focus.track_id, 'track-0');
});

test('recommendation batches advance seven, wrap, and remain usable for short days', () => {
  assert.equal(nextRecommendationIndex(0, 30, 1), 7);
  assert.equal(nextRecommendationIndex(28, 30, 1), 0);
  assert.equal(nextRecommendationIndex(0, 30, -1), 28);
  assert.equal(nextRecommendationIndex(0, 7, 1), 0);
  assert.equal(nextRecommendationIndex(0, 0, 1), 0);
});

test('next, previous and autoplay follow the playing recommendation without resetting manual browsing on pause', () => {
  const keyOf = item => `rec:${item.track_id}`;
  let focus = playbackFocus(tracks, keyOf, 'rec:track-5', null, 'track-0');
  assert.equal(focus, 'track-5');
  focus = playbackFocus(tracks, keyOf, 'rec:track-6', 'rec:track-5', focus);
  assert.equal(orbitItems(tracks, focus).focus.track_id, 'track-6');
  assert.equal(playbackFocus(tracks, keyOf, 'rec:track-5', 'rec:track-6', focus), 'track-5');
  assert.equal(playbackFocus(tracks, keyOf, 'rec:track-6', 'rec:track-6', 'track-12'), 'track-12');
  assert.equal(playbackFocus(tracks, keyOf, 'local:song', 'rec:track-6', 'track-12'), 'track-12');
  assert.equal(playbackFocus([], keyOf, 'rec:removed', null, null), null);
});

test('the stem flows vertically through library coordinates and every leaf joint stays on its curve', () => {
  const start = treeGeometry(0), next = treeGeometry(1);
  assert.notEqual(start.path, next.path);
  for (let slot = 0; slot < 6; slot++) {
    assert.equal(start.anchors[slot + 1].x, next.anchors[slot].x);
    assert.equal(start.anchors[slot + 1].y - next.anchors[slot].y, 91);
  }
  for (const scroll of [0, .25, .75, 1, 50, 1000]) {
    const geometry = treeGeometry(scroll);
    assert.equal(geometry.anchors.length, 7);
    geometry.anchors.forEach(anchor => {
      assert.ok(anchor.x >= 500 && anchor.x <= 604);
      assert.ok(geometry.path.includes(` ${anchor.x} ${anchor.y}`), 'leaf joins a curve endpoint');
    });
    const adjacent = treeGeometry(scroll + .001);
    assert.ok(Math.abs(geometry.anchors[0].x - adjacent.anchors[0].x) < .06, 'fractional scroll is continuous');
  }
});
