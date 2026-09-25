const { test } = require('node:test');
const assert = require('node:assert/strict');
const { downloadStage } = require('../web/onboarding.js');

test('a like or queued attempt is never described as a completed download', () => {
  assert.equal(downloadStage({ liked: false }), 'none');
  for (const state of ['WANTED', 'RESOLVING', 'DOWNLOADING', 'VALIDATING', 'RETRY_WAIT']) {
    assert.equal(downloadStage({ liked: true }, { state }), 'pending');
  }
  assert.equal(downloadStage({ liked: true }, { state: 'UNAVAILABLE' }), 'attention');
  assert.equal(downloadStage({ liked: true, local_status: 'LOCAL' }), 'ready');
});

test('fresh queue state overrides an older recommendation snapshot', () => {
  assert.equal(downloadStage({ wanted: { state: 'WANTED' } }, { state: 'LOCAL' }), 'ready');
  assert.equal(downloadStage({ wanted: { state: 'DOWNLOADING' } }, { state: 'UNAVAILABLE' }), 'attention');
  assert.equal(downloadStage({ local_status: 'REMOTE', wanted: { state: 'LOCAL' } }), 'ready');
});
