const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { setTimeout: delay } = require('node:timers/promises');
const server = spawn(process.argv[2], [], { stdio: 'ignore' });
const base = 'http://127.0.0.1:19876';
async function post(path, body) { assert.equal((await fetch(base + path, { method: 'POST', body: JSON.stringify(body) })).status, 200); }
async function sessions() { return (await fetch(base + '/sessions')).json(); }
async function runtime(stream, state) { await post('/codex-runtime-snapshot', {
  stream_id: stream, sessions: [{ session_id: 'chat', state, revision: 1 }],
}); }
async function snapshot(time, active = []) { await post('/codex-snapshot', {
  source: 'codex-jsonl', active, titles: { chat: 'Chat' }, sidebar_order: ['chat'], activity_at: { chat: time },
}); }
(async () => {
  try {
    for (let i = 0; i < 50; i++) { try { await sessions(); break; } catch { await delay(100); } }
    const old = Date.now() - 3600_000;
    await runtime('first', 'idle'); await snapshot(old);
    assert.deepEqual(await sessions(), []); // Replaying a completed old task cannot make a new green lamp.
    await runtime('reconnected', 'idle'); await snapshot(old);
    assert.deepEqual(await sessions(), []); // A fresh runtime stream isn't a new task.
    await snapshot(Date.now(), [{ session_id: 'chat', turn_id: 'new', state: 'executing' }]);
    await runtime('reconnected', 'executing');
    assert.equal((await sessions())[0].state, 'executing');
    const completed = Date.now();
    await runtime('reconnected', 'idle'); await snapshot(completed);
    assert.equal((await sessions())[0].state, 'idle');
    for (let i = 0; i < 8; i++) {
      await delay(1000); await runtime('restart-' + i, 'idle'); await snapshot(completed);
    }
    assert.deepEqual(await sessions(), []); // Heartbeats/reconnections don't renew retention.
    console.log('PASS: historical completion expires immediately, reconnect preserves clock, new task retained, idle heartbeat expiry');
  } finally { server.kill(); }
})().catch(e => { console.error(e); process.exitCode = 1; });
