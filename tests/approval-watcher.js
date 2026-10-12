const assert = require('node:assert/strict');
const { newRolloutState, inspectRecord, isApprovalCall } = require('../lights-codex-desktop-watcher');
const { stateFor } = require('../Resources/lights-codex-hook');
assert.equal(stateFor('PreToolUse', {tool_name: 'functions.request_permissions'}), 'permission');
assert.equal(stateFor('PreToolUse', {tool_name: 'exec_command', tool_input: {sandbox_permissions: 'require_escalated'}}), 'permission');
assert.equal(stateFor('PreToolUse', {tool_name: 'exec_command'}), 'executing');
const state = newRolloutState();
function record(payload, type = 'response_item') {
  inspectRecord(Buffer.from(JSON.stringify({ type, timestamp: new Date().toISOString(), payload })), state);
}
const call = (id, input, name = 'exec') => record({ type: 'custom_tool_call', call_id: id, name, input });
const output = (id, text) => record({ type: 'custom_tool_call_output', call_id: id, output: text });
record({ type: 'task_started', turn_id: 'turn-1' }, 'event_msg');
call('permission', 'await tools.request_permissions({});');
assert.equal(state.pendingCalls.size, 1);
output('unrelated', 'done');
assert.equal(state.lastEvent.state, 'permission');
output('permission', 'Script running with cell ID 12');
assert.equal(state.pendingCalls.size, 1);
assert.equal(state.completedCalls.has('permission'), false);
call('wait-1', '{"cell_id":"12"}', 'wait');
output('wait-1', 'Script running with cell ID 12');
assert.equal(state.pendingCalls.size, 1);
call('second-permission', 'await tools.request_permissions({});');
call('wait-2', '{"cell_id":"12"}', 'wait');
output('wait-2', 'Script completed');
assert.deepEqual([...state.pendingCalls], ['second-permission']);
assert.equal(state.completedCalls.has('permission'), true);
output('second-permission', 'permissions granted');
assert.equal(state.lastEvent.state, 'executing');
assert.equal(state.completedCalls.has('second-permission'), true);
assert.equal(isApprovalCall({ name: 'exec', input: 'await tools.exec_command({cmd:"echo tools.request_permissions()"});' }), false);
assert.equal(isApprovalCall({ name: 'exec', input: '// tools.request_permissions()\nawait tools.exec_command({cmd:"ls"});' }), false);
assert.equal(isApprovalCall({ name: 'exec', input: 'await tools.exec_command({sandbox_permissions: "require_escalated"});' }), true);
call('pending-at-end', 'await tools.request_permissions({});');
output('pending-at-end', 'Script running with cell ID 99');
record({ type: 'turn_aborted', turn_id: 'turn-1' }, 'event_msg');
assert.equal(state.pendingCalls.size, 0);
assert.equal(state.pendingCells.size, 0);
assert.equal(state.lastEvent.state, 'idle');
console.log('PASS: yielded approvals, repeated waits, parallel calls, false-positive filtering, abort cleanup');
const historical = newRolloutState();
const completedAt = Date.now() - 3600_000;
inspectRecord(Buffer.from(JSON.stringify({ type: 'event_msg', timestamp: new Date(completedAt).toISOString(),
  payload: { type: 'task_complete', turn_id: 'old' } })), historical);
assert.equal(historical.lastTaskAt, completedAt);
inspectRecord(Buffer.from(JSON.stringify({ type: 'response_item', timestamp: new Date().toISOString(),
  payload: { type: 'function_call_output', call_id: 'old', output: 'late result' } })), historical);
assert.equal(historical.lastTaskAt, completedAt);
console.log('PASS: real lifecycle timestamp survives historical replay and late outputs');
const questions = newRolloutState();
const questionRecord = payload => inspectRecord(Buffer.from(JSON.stringify({ type: 'response_item',
  timestamp: new Date().toISOString(), payload })), questions);
questionRecord({ type: 'function_call', name: 'request_user_input_async', call_id: 'ask',
  arguments: JSON.stringify({ questions: [{ title: 'A' }, { title: 'B' }] }) });
questionRecord({ type: 'function_call_output', call_id: 'ask', output: '{"accepted":true}' });
assert.equal(questions.pendingQuestions.size, 2); // Returning from the tool is not answering.
const reply = (index, role = 'user', answer = '') => questionRecord({ type: 'message', role,
  content: [{ type: 'input_text', text: '<send_user_message_question_reply>'
    + JSON.stringify([{ questionItemId: JSON.stringify(['request_user_input_async', 'ask', index]), answer }])
    + '</send_user_message_question_reply>' }] });
reply(0, 'assistant'); assert.equal(questions.pendingQuestions.size, 2);
reply(0, 'user', 'answered'); assert.equal(questions.pendingQuestions.size, 1);
reply(1); assert.equal(questions.pendingQuestions.size, 0); // Skip resolves the matching question.
questionRecord({ type: 'function_call', name: 'request_user_input_async', call_id: 'finished',
  arguments: '{"questions":[{"title":"Unanswered"}]}' });
questionRecord({ type: 'function_call_output', call_id: 'finished', output: '{"accepted":true}' });
questionRecord({ type: 'function_call', name: 'request_user_input_async', call_id: 'late',
  arguments: '{"questions":[{"title":"Late acceptance"}]}' });
assert.equal(questions.pendingQuestions.size, 1);
inspectRecord(Buffer.from(JSON.stringify({ type: 'event_msg', timestamp: new Date().toISOString(),
  payload: { type: 'task_complete', turn_id: 'done' } })), questions);
assert.equal(questions.pendingQuestions.size, 0); // Completion dismisses the lamp, not the actual card.
assert.equal(questions.asyncQuestionCandidates.size, 0);
assert.equal(questions.lastEvent.state, 'idle');
questionRecord({ type: 'function_call_output', call_id: 'late', output: '{"accepted":true}' });
assert.equal(questions.pendingQuestions.size, 0); // Late acceptance cannot reopen a completed question.
questionRecord({ type: 'function_call', name: 'request_user_input_async', call_id: 'ask',
  arguments: '{"questions":[{"title":"Aborted task"}]}' });
questionRecord({ type: 'function_call_output', call_id: 'ask', output: '{"accepted":true}' });
inspectRecord(Buffer.from(JSON.stringify({ type: 'event_msg', timestamp: new Date().toISOString(),
  payload: { type: 'turn_aborted', turn_id: 'background' } })), questions);
assert.equal(questions.pendingQuestions.size, 1); // Stopping work isn't answering the card.
reply(0); assert.equal(questions.pendingQuestions.size, 0);
questionRecord({ type: 'function_call', name: 'request_user_input_async', call_id: 'rejected',
  arguments: '{"questions":[{"title":"C"}]}' });
questionRecord({ type: 'function_call_output', call_id: 'rejected', output: '{"accepted":false}' });
assert.equal(questions.pendingQuestions.size, 0);
console.log('PASS: accepted async questions, per-question answers, skip, completion cleanup, late acceptance, rejection, quoted reply filtering');
questionRecord({ type: 'function_call', name: 'request_user_input_async', call_id: 'superseded',
  arguments: '{"questions":[{"title":"D"}]}' });
questionRecord({ type: 'function_call_output', call_id: 'superseded', output: '{"accepted":true}' });
questionRecord({ type: 'message', role: 'user', content: [{ text: '<environment_context>context</environment_context>' }] });
assert.equal(questions.pendingQuestions.size, 1);
questionRecord({ type: 'message', role: 'user', content: [{ text: 'Start a new task' }] });
assert.equal(questions.pendingQuestions.size, 0);
console.log('PASS: ordinary new user task supersedes abandoned questions, injected context does not');
