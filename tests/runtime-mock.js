#!/usr/bin/env node
process.stdin.on('data', chunk => { process.stdout.write(chunk); process.stderr.write(chunk); });
process.stdin.on('end', () => { process.exitCode = 23; });
