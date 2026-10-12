'use strict';
const { spawn } = require('node:child_process');
const http = require('node:http');
const { randomUUID } = require('node:crypto');
const { StringDecoder } = require('node:string_decoder');
const { existsSync } = require('node:fs');

class RuntimeObserver {
  constructor() { this.sessions = new Map(); this.pending = new Map(); this.reads = new Map(); this.revision = 0; this.epochs = new Map(); }
  set(id, state) {
    if (typeof id !== 'string' || !id) return;
    if (this.sessions.get(id)?.state !== state)
      this.sessions.set(id, { session_id: id, state, revision: ++this.revision });
  }
  waiting(id) { return [...this.pending.values()].includes(id); }
  clearPending(id) { for (const [key, thread] of this.pending) if (thread === id) this.pending.delete(key); }
  advance(id) { if (typeof id === 'string') this.epochs.set(id, (this.epochs.get(id) || 0) + 1); }
  status(id, status) {
    if (!status) return;
    if (status.type === 'active') {
      const flags = status.activeFlags || [];
      const waiting = flags.includes('waitingOnApproval') || flags.includes('waitingOnUserInput');
      // Authoritative current status supersedes our request bookkeeping. A
      // resolved/cancelled request may lack a matching client response here.
      if (!waiting) this.clearPending(id);
      this.set(id, waiting ? 'permission' : 'executing');
    } else if (['idle', 'notLoaded', 'systemError'].includes(status.type)) {
      this.clearPending(id);
      this.set(id, 'idle');
    }
  }
  client(m) {
    const key = JSON.stringify(m.id);
    if (m.method === 'thread/read' || m.method === 'thread/resume') {
      const id = m.params?.threadId;
      if (this.reads.size < 1024) this.reads.set(key, { id, epoch: this.epochs.get(id) || 0 });
    }
    if (!m.method && Object.hasOwn(m, 'id') && this.pending.has(key)) {
      const id = this.pending.get(key); this.pending.delete(key);
      this.advance(id);
      this.set(id, this.waiting(id) ? 'permission' : 'executing');
    }
  }
  server(m) {
    const p = m.params || {}, id = p.threadId;
    const approval = /(?:requestApproval|requestUserInput)$/.test(m.method || '')
      || m.method === 'mcpServer/elicitation/request';
    if (approval && Object.hasOwn(m, 'id') && typeof id === 'string') {
      this.advance(id);
      this.pending.set(JSON.stringify(m.id), id); this.set(id, 'permission');
    } else if (m.method === 'serverRequest/resolved') {
      const key = JSON.stringify(p.requestId), thread = this.pending.get(key);
      this.pending.delete(key);
      this.advance(thread || id);
      if (thread) this.set(thread, this.waiting(thread) ? 'permission' : 'executing');
    } else if (m.method === 'thread/status/changed') { this.advance(id); this.status(id, p.status); }
    else if (m.method === 'thread/started') { this.advance(p.thread?.id); this.status(p.thread?.id, p.thread?.status); }
    else if (m.method === 'turn/started') { this.advance(id); this.set(id, this.waiting(id) ? 'permission' : 'executing'); }
    else if (m.method === 'turn/completed') { this.advance(id); this.status(id, { type: 'idle' }); }
    else if (Object.hasOwn(m, 'id') && this.reads.has(JSON.stringify(m.id))) {
      const key = JSON.stringify(m.id), thread = m.result?.thread;
      const request = this.reads.get(key);
      this.reads.delete(key);
      if (thread && request.id === thread.id && (this.epochs.get(thread.id) || 0) === request.epoch) {
        this.advance(thread.id);
        this.status(thread.id, thread.status);
      }
    }
  }
  snapshot() { return [...this.sessions.values()]; }
}

// Parsing is optional and bounded. Original bytes always pass through unchanged.
function jsonLines(onMessage) {
  const decoder = new StringDecoder('utf8'); let line = '', skipping = false;
  return chunk => {
    const parts = decoder.write(chunk).split('\n');
    for (let i = 0; i < parts.length; i++) {
      if (!skipping) {
        line += parts[i];
        if (line.length > 16 * 1024 * 1024) { line = ''; skipping = true; }
      }
      if (i < parts.length - 1) {
        if (!skipping) { try { onMessage(JSON.parse(line)); } catch {} }
        line = ''; skipping = false;
      }
    }
  };
}

function run() {
  const args = process.argv.slice(2);
  const binary = process.env.LIGHTS_CODEX_REAL_BINARY
    || (existsSync('/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex')
      ? '/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex'
      : '/Applications/Codex.app/Contents/Resources/codex');
  const env = { ...process.env }; delete env.CODEX_CLI_PATH;
  const child = spawn(binary, args, { env, stdio: ['pipe', 'pipe', 'pipe'] });
  const observer = new RuntimeObserver(), streamID = randomUUID();
  const listenIndex = args.indexOf('--listen');
  const listen = listenIndex >= 0 ? args[listenIndex + 1]
    : args.find(a => a.startsWith('--listen='))?.slice('--listen='.length);
  const monitor = args.includes('app-server') && (!listen || listen === 'stdio://');
  let inFlight = false, closing = false;
  const port = Number(process.env.LIGHTS_RUNTIME_PORT || 9876);
  function send(release = false) {
    if ((!release && inFlight) || !monitor) return;
    const body = JSON.stringify({ stream_id: streamID, sessions: release ? [] : observer.snapshot() });
    inFlight = true;
    const req = http.request({ hostname: '127.0.0.1', port, path: '/codex-runtime-snapshot', method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) } }, res => res.resume());
    req.setTimeout(800, () => req.destroy());
    req.on('error', () => {}); req.on('close', () => { inFlight = false; }); req.end(body);
  }
  if (monitor) {
    child.stdout.on('data', jsonLines(m => { observer.server(m); send(); }));
    process.stdin.on('data', jsonLines(m => { observer.client(m); send(); }));
  }
  process.stdin.pipe(child.stdin); child.stdout.pipe(process.stdout); child.stderr.pipe(process.stderr);
  child.stdin.on('error', () => {});
  const timer = setInterval(() => send(), 1000); timer.unref();
  for (const signal of ['SIGTERM', 'SIGINT', 'SIGHUP']) process.on(signal, () => child.kill(signal));
  child.on('error', error => { process.stderr.write(`Lights bridge: ${error.message}\n`); process.exitCode = 1; process.stdin.destroy(); clearInterval(timer); });
  child.on('close', (code, signal) => {
    if (closing) return; closing = true; clearInterval(timer); process.stdin.destroy();
    send(true); process.exitCode = code ?? (signal ? 1 : 0);
  });
}
module.exports = { RuntimeObserver, jsonLines };
if (require.main === module) run();
