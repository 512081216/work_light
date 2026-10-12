const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { setTimeout: delay } = require('node:timers/promises');
const server = spawn(process.argv[2], [], { stdio: 'ignore' });
const base = 'http://127.0.0.1:19876';
async function post(path, payload) {
  const res = await fetch(base + path, { method: 'POST', body: JSON.stringify(payload) });
  assert.equal(res.status, 200);
}
async function state() { return (await (await fetch(base + '/sessions')).json()).find(s => s.id === 'market')?.state; }
const snapshot = (state, revision = 1, stream = 'live') => post('/codex-runtime-snapshot', {
  stream_id: stream, sessions: [{ session_id: 'market', state, revision }],
});
const fallback = () => post('/codex-snapshot', { source: 'codex-jsonl', active: [{ session_id: 'market', turn_id: 'turn', state: 'executing' }] });
(async () => {
  try {
    for (let i = 0; i < 50; i++) { try { await fetch(base + '/health'); break; } catch { await delay(100); } }
    await fallback(); await snapshot('permission'); await fallback();
    assert.equal(await state(), 'permission');
    await snapshot('executing', 2); assert.equal(await state(), 'executing');
    await snapshot('idle', 3); await fallback(); assert.equal(await state(), 'idle');
    await post('/codex-runtime-snapshot', { stream_id: 'unrelated', sessions: [] });
    assert.equal(await state(), 'idle');
    await snapshot('permission', 4); await delay(5500);
    assert.equal(await state(), 'executing'); // Dead bridge falls back, never leaves sticky yellow.
    for (let i = 0; i < 8; i++) { await snapshot('idle', 5); await fallback(); await delay(1000); }
    assert.equal(await state(), undefined); // Idle heartbeats don't keep conversation alive.
    await post('/codex-runtime-snapshot', { stream_id: 'live', sessions: [] });
    assert.equal(await state(), 'executing');
    console.log('PASS: runtime beats JSONL, resolution, idle authority, stream isolation, dead bridge expiry, retention');
  } finally { server.kill(); }
})().catch(e => { console.error(e); process.exitCode = 1; });
