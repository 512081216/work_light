const assert = require('node:assert/strict');
const { assess } = require('../tools/check-codex-hooks');
const events = ['sessionStart', 'userPromptSubmit', 'preToolUse',
  'permissionRequest', 'postToolUse', 'stop'];
const hooks = events.map(eventName => ({ eventName, enabled: true,
  trustStatus: 'trusted', command: 'node lights-codex-hook.js' }));
const result = list => assess({data: [{hooks: list, errors: []}]});
assert.equal(result(hooks).ready, true);
for (const trustStatus of ['untrusted', 'modified']) {
  assert.equal(result(hooks.map(h => h.eventName === 'permissionRequest'
    ? {...h, trustStatus} : h)).ready, false);
}
assert.equal(result(hooks.map(h => ({...h, enabled: false}))).ready, false);
assert.deepEqual(result(hooks.filter(h => h.eventName !== 'permissionRequest')).missing,
  ['permissionRequest']);
assert.equal(assess({data: [{hooks, errors: [{message: 'invalid hook'}]}]}).ready, false);
assert.throws(() => assess({}), /Missing/);
console.log('PASS: trusted, modified, untrusted, disabled, missing, and failed hook diagnostics');
