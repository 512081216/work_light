#!/usr/bin/env node
// Read-only hooks/list diagnostic. Never writes hook trust or approval policy.
'use strict';
const { spawn } = require('node:child_process');
const requiredEvents = ['sessionStart', 'userPromptSubmit', 'preToolUse',
  'permissionRequest', 'postToolUse', 'stop'];

function assess(result) {
  const entries = result?.data;
  if (!Array.isArray(entries) || !entries.length) throw new Error('Missing hooks/list data');
  const hooks = entries.flatMap(entry => entry.hooks || [])
    .filter(hook => hook.command?.includes('lights-codex-hook.js'));
  const errors = entries.flatMap(entry => entry.errors || []);
  const missing = requiredEvents.filter(event => !hooks.some(hook => hook.eventName === event));
  const blocked = hooks.filter(hook => !hook.enabled
    || !['trusted', 'managed'].includes(hook.trustStatus));
  return { ready: !errors.length && !missing.length && !blocked.length,
    missing, errors, hooks: hooks.map(({eventName, key, enabled, trustStatus}) =>
      ({eventName, key, enabled, trustStatus})) };
}

function check(codex = 'codex', cwd = process.cwd()) {
  return new Promise((resolve, reject) => {
    const child = spawn(codex, ['app-server', '--stdio'], {stdio: ['pipe', 'pipe', 'ignore']});
    let buffer = '', settled = false;
    const finish = (error, result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      child.kill();
      if (error) reject(error); else resolve(result);
    };
    const timer = setTimeout(() => finish(new Error('hooks/list timed out')), 8000);
    const send = message => child.stdin.write(JSON.stringify(message) + '\n');
    child.on('error', error => finish(error));
    child.stdin.on('error', error => finish(error));
    child.on('exit', () => finish(new Error('Codex exited before hooks/list returned')));
    child.stdout.on('data', chunk => {
      buffer += chunk;
      let newline;
      while ((newline = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, newline); buffer = buffer.slice(newline + 1);
        let message;
        try { message = JSON.parse(line); } catch { continue; }
        if (![1, 2].includes(message.id)) continue;
        if (message.error) { finish(new Error(message.error.message)); return; }
        if (message.id === 1) {
          send({method: 'initialized'});
          send({id: 2, method: 'hooks/list', params: {cwds: [cwd]}});
        } else {
          try { finish(null, assess(message.result)); }
          catch (error) { finish(error); }
        }
      }
    });
    send({id: 1, method: 'initialize', params: {
      clientInfo: {name: 'lights-hook-check', version: '1'},
      capabilities: {experimentalApi: true}}});
  });
}

if (require.main === module) {
  check(process.env.LIGHTS_CODEX_BIN || 'codex').then(result => {
    console.log(JSON.stringify(result, null, 2));
    if (!result.ready) {
      console.error('Lights hooks are not ready. Open Codex CLI /hooks, review Lights hooks, then recheck.');
      process.exitCode = 1;
    }
  }).catch(error => { console.error(error.message); process.exitCode = 2; });
}
module.exports = { assess, check };
