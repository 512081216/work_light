const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { setTimeout: delay } = require('node:timers/promises');
const server = spawn(process.argv[2], [], { stdio: 'ignore' });
const base = 'http://127.0.0.1:19876';
async function post(path, body) {
  assert.equal((await fetch(base + path, { method: 'POST', body: JSON.stringify(body) })).status, 200);
}
async function sessions() { return (await fetch(base + '/sessions')).json(); }
async function status() { return (await fetch(base + '/status')).text(); }
const runtime = states => post('/codex-runtime-snapshot', { stream_id: 'live', sessions:
  Object.entries(states).map(([session_id, state]) => ({ session_id, state, revision: 1 })) });
const roster = (ids, active = []) => post('/codex-snapshot', { source: 'codex-jsonl',
  active, sidebar_order: ids, titles: Object.fromEntries(ids.map(id => [id, id])) });
(async () => {
  try {
    for (let i = 0; i < 50; i++) { try { await sessions(); break; } catch { await delay(100); } }
    await runtime({ guardian: 'executing', market: 'executing' });
    assert.deepEqual(await sessions(), []); // No top-level roster evidence yet.
    await roster(['market']);
    assert.deepEqual((await sessions()).map(s => [s.id, s.state]), [['market', 'executing']]);
    await runtime({ guardian: 'permission', market: 'idle' });
    assert.equal(await status(), 'idle'); // Hidden child cannot affect the single lamp either.
    await post('/codex-event', { source: 'codex-official', session_id: 'guardian', event: 'PreToolUse', state: 'executing' });
    assert.deepEqual((await sessions()).map(s => s.id), ['market']);
    await runtime({ guardian: 'executing', market: 'idle', second: 'executing' });
    await roster(['second', 'market']);
    assert.deepEqual((await sessions()).map(s => [s.id, s.state]), [['second', 'executing'], ['market', 'idle']]);
    await roster(['market']);
    assert.deepEqual((await sessions()).map(s => s.id), ['market']);
    await roster([]); assert.deepEqual(await sessions(), []); assert.equal(await status(), 'idle');
    console.log('PASS: runtime-only threads hidden, guardian excluded, aggregate filtered, legitimate second chat retained, sidebar order, roster removal');
  } finally { server.kill(); }
})().catch(e => { console.error(e); process.exitCode = 1; });
