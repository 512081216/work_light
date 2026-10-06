#!/usr/bin/env node

/*
 * Fallback bridge for the Codex desktop app's local rollout files.
 *
 * Official Codex hooks are the authoritative path. This watcher is only a
 * rescue path for desktop builds that do not emit hooks. It sends structured
 * per-session events plus an authoritative snapshot of every open JSONL turn.
 */

const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync, spawnSync } = require("child_process");

const codexHome = process.env.LIGHTS_CODEX_HOME
  || process.env.CODEX_HOME
  || path.join(os.homedir(), ".codex");
const database = path.join(codexHome, "state_5.sqlite");
const endpoint = "http://127.0.0.1:9876";
const pollMs = 1000;
const activeWindowMs = 15000;

const rolloutCache = new Map();

function newRolloutState() {
  return {
    offset: 0, carry: Buffer.alloc(0), activeTask: false,
    activeTaskTurnId: null, lastActivityAt: 0,
    pendingCalls: new Set(), pendingCells: new Map(), waitCalls: new Map(),
    lastEvent: null, lastSentKey: null,
  };
}

function sessionIdFromRollout(file) {
  const name = path.basename(file);
  const match = name.match(
    /^rollout-.+-([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(?:_.+)?\.jsonl$/i
  );
  return match ? match[1] : name;
}

function notifyEvent(file, event, stateName, turnId = null) {
  const cache = rolloutCache.get(file);
  const key = `${file}|${event}|${turnId || ""}`;
  if (cache && cache.lastSentKey === key) return;

  const body = JSON.stringify({
    event,
    state: stateName,
    source: "codex-jsonl",
    session_id: sessionIdFromRollout(file),
    ...(turnId ? { turn_id: turnId } : {}),
  });
  const result = spawnSync("/usr/bin/curl", [
    "-s", "--max-time", "1",
    "-H", "Content-Type: application/json",
    "-d", body,
    `${endpoint}/codex-event`,
  ], { stdio: "ignore" });
  // Retry when Lights was temporarily closed or not ready yet.
  if (cache) {
    cache.lastSentKey = result.status === 0 ? key : null;
  }
}

function notifySnapshot(active, threads) {
  const body = JSON.stringify({
    source: "codex-jsonl", active,
    sidebar_order: threads.map(t => t.id),
    titles: Object.fromEntries(threads.map(t => [t.id, t.title])),
  });
  spawnSync("/usr/bin/curl", [
    "-s", "--max-time", "1",
    "-H", "Content-Type: application/json",
    "-d", body,
    `${endpoint}/codex-snapshot`,
  ], { stdio: "ignore" });
}

function rolloutPaths() {
  if (!fs.existsSync(database)) return null;
  try {
    const sql = [
      "SELECT id, COALESCE(NULLIF(name, ''), substr(title, 1, 120)) AS title,",
      "cwd, project_id, section_position, is_pinned,",
      "COALESCE(recency_at_ms, updated_at_ms) AS recency, rollout_path FROM threads",
      "WHERE archived = 0 AND rollout_path IS NOT NULL AND source NOT LIKE '%subagent%'",
      "ORDER BY updated_at_ms DESC LIMIT 256;",
    ].join(" ");
    const output = execFileSync("/usr/bin/sqlite3", [
      "-json", database, sql,
    ], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
    return sidebarOrderedThreads(JSON.parse(output || "[]"));
  } catch {
    // A transient database failure is not evidence that every turn ended.
    return null;
  }
}

function sidebarOrderedThreads(threads) {
  let global = {};
  try { global = JSON.parse(fs.readFileSync(path.join(codexHome, ".codex-global-state.json"), "utf8")); }
  catch { /* Database recency remains a deterministic fallback. */ }
  const prefs = global["electron-persisted-atom-state"]?.["flat-project-sidebar-preferences-v1"] || {};
  const pinned = global["pinned-thread-ids"] || [];
  const pinnedProjects = global["pinned-project-ids"] || [];
  const projectOrder = global["project-order"] || [];
  const assignments = global["thread-project-assignments"] || {};
  const manualOrders = global["sidebar-project-thread-orders"] || {};
  const projectFor = t => assignments[t.id]?.projectId || t.project_id || null;
  const projects = [...pinnedProjects, ...projectOrder.filter(id => !pinnedProjects.includes(id))];
  const rank = t => {
    const pin = pinned.indexOf(t.id);
    if (pin >= 0 || t.is_pinned) return [0, pin < 0 ? 999 : pin, 0];
    const project = projectFor(t);
    if (prefs.mode === "list" || !project) return [2, 0, 0];
    const projectIndex = projects.indexOf(project);
    const manual = manualOrders[project];
    const manualIndex = Array.isArray(manual) ? manual.indexOf(t.id) : -1;
    const position = prefs.chatSortMode === "manual"
      ? (manualIndex >= 0 ? manualIndex : t.section_position ?? 1000000) : 0;
    return [1, projectIndex < 0 ? 999 : projectIndex, position];
  };
  return threads.sort((a, b) => {
    const ra = rank(a), rb = rank(b);
    for (let i = 0; i < ra.length; i++) if (ra[i] !== rb[i]) return ra[i] - rb[i];
    return b.recency - a.recency || a.id.localeCompare(b.id);
  });
}

function inspectRollout(file) {
  let stat;
  try {
    stat = fs.statSync(file);
  } catch {
    return null;
  }

  const ageMs = Date.now() - stat.mtimeMs;
  let state = rolloutCache.get(file);
  if (!state || stat.size < state.offset) {
    state = newRolloutState();
    rolloutCache.set(file, state);
  }

  // Rollouts are append-only JSONL files. Read only bytes not seen by this
  // process; this preserves task boundaries even for very large files.
  try {
    const fd = fs.openSync(file, "r");
    try {
      while (state.offset < stat.size) {
        const length = Math.min(1024 * 1024, stat.size - state.offset);
        const chunk = Buffer.allocUnsafe(length);
        const bytesRead = fs.readSync(fd, chunk, 0, length, state.offset);
        if (bytesRead <= 0) break;
        state.offset += bytesRead;

        const data = state.carry.length
          ? Buffer.concat([state.carry, chunk.subarray(0, bytesRead)])
          : chunk.subarray(0, bytesRead);
        let lineStart = 0;
        for (let lineEnd = data.indexOf(0x0a); lineEnd >= 0;
             lineEnd = data.indexOf(0x0a, lineStart)) {
          inspectRecord(data.subarray(lineStart, lineEnd), state);
          lineStart = lineEnd + 1;
        }
        state.carry = data.subarray(lineStart);
      }
    } finally {
      fs.closeSync(fd);
    }
  } catch {
    return null;
  }

  const waiting = state.activeTask && state.pendingCalls.size > 0;
  const activeAgeMs = state.lastActivityAt
    ? Date.now() - state.lastActivityAt : ageMs;
  return {
    ageMs,
    activeAgeMs,
    activeTaskTurnId: state.activeTaskTurnId,
    // The explicit JSONL turn boundary is authoritative. File recency alone
    // must never resurrect a turn that already emitted task_complete.
    active: state.activeTask,
    waiting,
    lastEvent: state.lastEvent,
  };
}

function inspectRecord(line, state) {
  if (!line.length) return;
  let record;
  try {
    record = JSON.parse(line.toString("utf8"));
  } catch {
    return;
  }
  const payload = record.payload || {};
  const turnId = payload.turn_id || payload.turnId || payload.task_id || null;
  const parsedTimestamp = Date.parse(record.timestamp);
  const occurredAt = Number.isFinite(parsedTimestamp) ? parsedTimestamp : Date.now();

  if (payload.type === "task_started") {
    state.activeTask = true;
    state.activeTaskTurnId = turnId || `jsonl-open-${occurredAt}`;
    state.pendingCalls.clear();
    state.pendingCells.clear();
    state.waitCalls.clear();
    state.lastActivityAt = occurredAt;
    state.lastEvent = {
      event: "event_msg:task_started",
      state: "executing",
      turnId: state.activeTaskTurnId,
    };
  }
  if (payload.type === "task_complete" || payload.type === "turn_aborted") {
    state.activeTask = false;
    state.activeTaskTurnId = null;
    state.pendingCalls.clear();
    state.pendingCells.clear();
    state.waitCalls.clear();
    state.lastActivityAt = occurredAt;
    state.lastEvent = {
      event: payload.type === "turn_aborted"
        ? "event_msg:turn_aborted" : "event_msg:task_complete",
      state: "idle",
      turnId,
    };
  }

  if (record.type !== "response_item" || !state.activeTask) return;
  state.lastActivityAt = occurredAt;
  if (payload.type === "custom_tool_call" || payload.type === "function_call") {
    const name = String(payload.name || "").split(".").pop();
    if (name === "wait") {
      try {
        const args = JSON.parse(payload.arguments || payload.input || "{}");
        if (state.pendingCells.has(String(args.cell_id))) {
          state.waitCalls.set(payload.call_id || payload.id, String(args.cell_id));
        }
      } catch { /* An invalid wait must not resolve another call's approval. */ }
    }
    if (isApprovalCall(payload)) {
      state.pendingCalls.add(payload.call_id || payload.id || "unknown");
      state.lastEvent = {
        event: "PermissionRequest", state: "permission",
        turnId: turnId || state.activeTaskTurnId,
      };
    }
  } else if (payload.type === "custom_tool_call_output" || payload.type === "function_call_output") {
    const callId = payload.call_id || "unknown";
    const output = typeof payload.output === "string" ? payload.output : JSON.stringify(payload.output || "");
    const runningCell = output.match(/Script running with cell ID\s+([\w-]+)/)?.[1];
    if (state.pendingCalls.has(callId)) {
      if (runningCell) state.pendingCells.set(runningCell, callId);
      else state.pendingCalls.delete(callId);
    }
    const waitedCell = state.waitCalls.get(callId);
    if (waitedCell) {
      if (!runningCell) {
        state.pendingCalls.delete(state.pendingCells.get(waitedCell));
        state.pendingCells.delete(waitedCell);
      }
      state.waitCalls.delete(callId);
    }
    const waiting = state.pendingCalls.size > 0;
    state.lastEvent = { event: waiting ? "PermissionRequest" : "PostToolUse",
      state: waiting ? "permission" : "executing", turnId: turnId || state.activeTaskTurnId };
  }
}

function isApprovalCall(payload) {
  const name = String(payload.name || "").split(".").pop();
  if (["request_user_input", "request_user_input_async", "request_permissions"].includes(name)) {
    return true;
  }
  // The desktop records orchestrated tools as an `exec` call containing JS;
  // direct tools use JSON arguments. Inspect only the tool-call input, never
  // transcript messages or returned text that may mention old approvals.
  const input = typeof payload.input === "string" ? payload.input
    : typeof payload.arguments === "string" ? payload.arguments : "";
  if (name === "exec") {
    // Ignore commands/comments/quoted examples mentioning an approval tool.
    // Keep character offsets so real escalation properties can be checked.
    const code = input.replace(/"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`|\/\/[^\n]*|\/\*[\s\S]*?\*\//g,
      match => " ".repeat(match.length));
    return /\btools\.request_permissions\s*\(/.test(code)
      || /\btools\.request_user_input(?:_async)?\s*\(/.test(code)
      || [...input.matchAll(/\bsandbox_permissions\s*:\s*["']require_escalated["']/g)]
        .some(match => code.slice(match.index).startsWith("sandbox_permissions"));
  }
  if (name === "exec_command") {
    try { return JSON.parse(input).sandbox_permissions === "require_escalated"; }
    catch { return false; }
  }
  return false;
}

function refresh() {
  const files = rolloutPaths();
  if (files === null) return;

  const activeBySession = new Map();
  for (const thread of files) {
    const file = thread.rollout_path;
    const state = inspectRollout(file);
    if (!state) continue;

    // Only recent files may contribute fallback state. Never replay an old
    // task_complete into the currently active Codex session.
    if (state.activeAgeMs <= activeWindowMs && state.lastEvent) {
      notifyEvent(file, state.lastEvent.event, state.lastEvent.state, state.lastEvent.turnId);
    } else if (state.waiting) {
      notifyEvent(file, "PermissionRequest", "permission");
    } else if (state.active) {
      notifyEvent(file, "event_msg:task_started", "executing", state.activeTaskTurnId);
    }

    if (state.active) {
      const sessionId = sessionIdFromRollout(file);
      const snapshotState = state.waiting ? "permission" : "executing";
      const previous = activeBySession.get(sessionId);
      if (!previous || snapshotState === "permission") {
        activeBySession.set(sessionId, {
          session_id: sessionId,
          turn_id: state.activeTaskTurnId,
          state: snapshotState,
        });
      }
    }
  }
  notifySnapshot(Array.from(activeBySession.values()), files);
}

function stop() {
  // Do not send idle here. Process shutdown is not evidence that Codex's
  // current turn ended, and a stale fallback process must not clear the lamp.
  process.exit(0);
}

if (require.main === module) {
  refresh();
  setInterval(refresh, pollMs);
  process.on("SIGINT", stop);
  process.on("SIGTERM", stop);
}
module.exports = { newRolloutState, inspectRecord, isApprovalCall };
