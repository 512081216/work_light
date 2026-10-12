const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const path = require('node:path');
const http = require('node:http');
const received = [];
const server = http.createServer((req, res) => {
  let body = ''; req.on('data', b => body += b); req.on('end', () => {
    received.push(JSON.parse(body)); res.end('ok');
  });
});
server.listen(0, '127.0.0.1', async () => {
  try {
    const child = spawn(process.execPath, [path.resolve(__dirname, '../tools/codex-runtime-bridge.js'), 'app-server', '--listen', 'stdio://'], {
      env: { ...process.env, LIGHTS_CODEX_REAL_BINARY: path.resolve(__dirname, 'runtime-mock.js'), LIGHTS_RUNTIME_PORT: String(server.address().port) },
    });
    const out = [], err = [];
    child.stdout.on('data', b => out.push(b)); child.stderr.on('data', b => err.push(b));
    const input = Buffer.from(JSON.stringify({ id: 1, method: 'mcpServer/elicitation/request', params: { threadId: 'market', secret: 'never-forward' } }) + '\nnot-json\n审批\n');
    const ended = new Promise(resolve => child.on('close', resolve));
    child.stdin.end(input);
    const code = await ended;
    assert.equal(code, 23);
    assert.deepEqual(Buffer.concat(out), input); assert.deepEqual(Buffer.concat(err), input);
    assert.ok(received.some(s => s.sessions.some(t => t.state === 'permission')));
    assert.ok(!JSON.stringify(received).includes('never-forward'));
    assert.ok(received.some(s => s.sessions.length === 0));
    console.log('PASS: byte-exact stdin/stdout/stderr, exit code, stdio option, sanitized live forwarding, stream release');
  } catch (e) { console.error(e); process.exitCode = 1; } finally { server.close(); }
});
