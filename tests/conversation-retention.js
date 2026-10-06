// Run with: node tests/conversation-retention.js /path/to/test-server
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { setTimeout: delay } = require('node:timers/promises');
const server = spawn(process.argv[2], [], { stdio: 'ignore' });
const base = 'http://127.0.0.1:19876';
async function snapshot(active, extra = {}) {
  const response = await fetch(base + '/codex-snapshot', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ source: 'codex-jsonl', active,
      sidebar_order: ['b', 'a'], titles: { a: 'A', b: 'B' }, ...extra }),
  });
  assert.equal(response.status, 200);
}
async function sessions() { return (await fetch(base + '/sessions')).json(); }
(async () => {
  try {
    for (let i = 0; i < 50; i++) {
      try { await sessions(); break; } catch { await delay(100); }
    }
    const work = id => ({ session_id: id, turn_id: 'turn-' + id, state: 'executing' });
    await snapshot([work('a'), work('b')]);
    assert.deepEqual((await sessions()).map(s => s.id), ['b', 'a']);
    await snapshot([]);
    await delay(4200); // Past the old three-second removal threshold.
    await snapshot([]);
    assert.deepEqual((await sessions()).map(s => s.state), ['idle', 'idle']);
    await snapshot([work('a')]);
    assert.deepEqual((await sessions()).map(s => [s.id, s.state]),
      [['b', 'idle'], ['a', 'executing']]);
    await snapshot([], { sidebar_order: [] }); // Bounded/missing sidebar is not archive evidence.
    assert.equal((await sessions()).length, 2);
    await delay(4200);
    await snapshot([]);
    assert.equal((await sessions()).length, 1); // Idle polls do not prematurely expire it.
    await delay(2000);
    await snapshot([]);
    assert.equal((await sessions()).length, 0); // Nor do they extend the timeout.
    await snapshot([work('a')]);
    await delay(6200);
    await snapshot([work('a')]);
    assert.equal((await sessions())[0].state, 'executing');
    await snapshot([{ ...work('a'), state: 'permission' }]);
    await delay(6200);
    await snapshot([{ ...work('a'), state: 'permission' }]);
    assert.equal((await sessions())[0].state, 'permission');
    console.log('PASS: idle retention/expiry, new task resets timer, stable order, work/approval never expire');
  } finally { server.kill('SIGTERM'); }
})().catch(error => { console.error(error); process.exitCode = 1; });
