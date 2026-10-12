const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { setTimeout: delay } = require('node:timers/promises');
const server = spawn(process.argv[2], [], { stdio: 'ignore' });
const base = 'http://127.0.0.1:19876';
async function post(path, body) { assert.equal((await fetch(base + path, { method: 'POST', body: JSON.stringify(body) })).status, 200); }
async function state() { return (await (await fetch(base + '/sessions')).json()).find(s => s.id === 'chat')?.state; }
async function questions(ids) { await post('/codex-snapshot', { source: 'codex-jsonl',
  titles: { chat: 'Chat' }, sidebar_order: ['chat'], active: [], pending_questions: ids,
  activity_at: { chat: Date.now() - 3600000 } }); }
(async () => {
  try {
    for (let i = 0; i < 50; i++) { try { await fetch(base + '/health'); break; } catch { await delay(100); } }
    await post('/codex-runtime-snapshot', { stream_id: 'runtime', sessions: [{ session_id: 'chat', state: 'executing', revision: 1 }] });
    await questions(['chat']); assert.equal(await state(), 'permission');
    await post('/codex-runtime-snapshot', { stream_id: 'runtime', sessions: [{ session_id: 'chat', state: 'idle', revision: 2 }] });
    await questions(['chat']); assert.equal(await state(), 'permission');
    await questions([]); assert.equal(await state(), 'idle');
    console.log('PASS: unanswered question overrides background execution/idle, response clears yellow');
  } finally { server.kill(); }
})().catch(e => { console.error(e); process.exitCode = 1; });
