const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { setTimeout: delay } = require('node:timers/promises');
const server = spawn(process.argv[2], [], { stdio: 'ignore' });
const base = 'http://127.0.0.1:19876';
const post = async (path, body) => assert.equal((await fetch(base + path, {
  method: 'POST', body: JSON.stringify(body),
})).status, 200);
const event = call_id => post('/codex-event', {
  source: 'codex-official', session_id: 'work', turn_id: 'turn', event: 'PermissionRequest', call_id,
});
const snapshot = completed => post('/codex-snapshot', {
  source: 'codex-jsonl', titles: { work: 'Work' }, sidebar_order: ['work'], pending_questions: [],
  active: [{ session_id: 'work', turn_id: 'turn', state: 'executing' }],
  completed_calls: { work: completed },
});
const state = async () => (await (await fetch(base + '/sessions')).json())[0].state;
(async () => {
  try {
    for (let i = 0; i < 50; i++) {
      try { await fetch(base + '/health'); break; } catch { await delay(100); }
    }
    await snapshot([]);
    await post('/codex-event', { source: 'codex-official', session_id: 'work', turn_id: 'turn',
      event: 'PreToolUse', state: 'permission', call_id: 'auto-approved' });
    await snapshot([]); assert.equal(await state(), 'executing');
    await event('a'); await event('b');
    await snapshot(['unrelated']); assert.equal(await state(), 'permission');
    await snapshot(['a']); assert.equal(await state(), 'permission');
    await snapshot(['a', 'b']); assert.equal(await state(), 'executing');
    await event('new'); await snapshot(['a', 'b']); assert.equal(await state(), 'permission');
    const diagnostics = await (await fetch(base + '/diagnostics')).json();
    assert.equal(diagnostics[0].official_approval_count, 1);
    await snapshot(['a', 'b', 'new']); assert.equal(await state(), 'executing');
    console.log('PASS: auto-approved PreToolUse does not latch, missing PostToolUse reconciled by exact call, parallel/new approvals preserved, read-only diagnostics');
  } finally { server.kill(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
