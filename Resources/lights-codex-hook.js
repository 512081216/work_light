#!/usr/bin/env node
// Lights Codex hook.  This deliberately sends the official hook payload's
// session/turn identity instead of a global /idle or /executing signal.
// The server applies the turn fence and aggregates multiple sessions.

"use strict";

const fs = require("fs");
const http = require("http");
const path = require("path");

const ENDPOINT = "http://127.0.0.1:9876/codex-event";
const MAX_STDIN_BYTES = 256 * 1024;

function readStdin() {
  return new Promise((resolve) => {
    const chunks = [];
    let total = 0;
    process.stdin.on("data", (chunk) => {
      total += chunk.length;
      if (total <= MAX_STDIN_BYTES) chunks.push(chunk);
    });
    process.stdin.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    process.stdin.on("error", () => resolve(""));
  });
}

function text(value) {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function sessionFromTranscript(transcriptPath) {
  const name = path.basename(String(transcriptPath || ""));
  const match = name.match(
    /^rollout-.+-([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(?:_.+)?\.jsonl$/i
  );
  return match ? match[1] : null;
}

function stateFor(event) {
  if (event === "PermissionRequest") return "permission";
  if (event === "SessionStart") return "idle";
  if (event === "Stop" || event === "SessionEnd") return "idle";
  if (event === "UserPromptSubmit" || event === "PreToolUse" || event === "PostToolUse") {
    return "executing";
  }
  return null;
}

function post(body) {
  return new Promise((resolve) => {
    const request = http.request(ENDPOINT, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Content-Length": Buffer.byteLength(body),
      },
      timeout: 900,
    }, (response) => {
      response.resume();
      response.on("end", resolve);
    });
    request.on("error", resolve);
    request.on("timeout", () => request.destroy());
    request.end(body);
  });
}

async function main() {
  let payload;
  try {
    payload = JSON.parse(await readStdin());
  } catch {
    return;
  }

  const event = text(payload.hook_event_name) || text(payload.event);
  if (!event || (event === "Stop" && payload.stop_hook_active === true)) return;
  const state = stateFor(event);
  if (!state) return;

  const transcriptPath = text(payload.transcript_path);
  const sessionId = text(payload.session_id)
    || sessionFromTranscript(transcriptPath)
    || "default";
  const turnId = text(payload.turn_id) || text(payload.turnId);
  const body = JSON.stringify({
    event,
    state,
    source: "codex-official",
    session_id: sessionId,
    ...(turnId ? { turn_id: turnId } : {}),
    ...(transcriptPath ? { transcript_path: transcriptPath } : {}),
    ...(text(payload.cwd) ? { cwd: text(payload.cwd) } : {}),
    ...(text(payload.tool_name) ? { tool_name: text(payload.tool_name) } : {}),
    ...(payload.stop_hook_active === true ? { stop_hook_active: true } : {}),
  });
  await post(body);
}

main().catch(() => {});
