const test = require('node:test');
const assert = require('node:assert/strict');
const { LeafWindow, orbitItems, nextRecommendationIndex } = require('../web/music-tree-ui.js');
const tracks = Array.from({ length: 30 }, (_, i) => ({ id: `library-${i}`, track_id: `track-${i}` }));

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
  assert.equal(many.orbit.length, 6);
  assert.equal(new Set([many.focus, ...many.orbit].map(x => x.track_id)).size, 7);
  assert.equal(orbitItems(tracks.slice(0, 3), 'removed').focus.track_id, 'track-0');
});

test('recommendation batches advance seven, wrap, and remain usable for short days', () => {
  assert.equal(nextRecommendationIndex(0, 30, 1), 7);
  assert.equal(nextRecommendationIndex(28, 30, 1), 5);
  assert.equal(nextRecommendationIndex(0, 30, -1), 23);
  assert.equal(nextRecommendationIndex(0, 7, 1), 1);
  assert.equal(nextRecommendationIndex(0, 0, 1), 0);
});
