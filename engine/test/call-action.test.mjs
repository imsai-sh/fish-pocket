import test from 'node:test';
import assert from 'node:assert/strict';
import { Context } from '@deepseek-ai/cordis';
import { createScope } from '@deepseek-ai/dsh-scope';
import { SystemPrompt } from '@deepseek-ai/dsh-system-prompt';
import ToolsService, { defineTool } from '@deepseek-ai/dsh-tools';
import { Bash, defineCommand } from 'just-bash';
import { CallToolExecutor } from '../plugins/ios-call/executor.mjs';
import { liveCall, recordSpokenAction, setCall, LEASE_MS } from '../plugins/ios-call/index.mjs';
import { endCallCommand } from '../runtime/end-call.mjs';

async function fixture(t) {
  const ctx = new Context();
  await ctx.plugin(SystemPrompt, {});
  await ctx.plugin(ToolsService, {});
  const tools = ctx.get('tools');
  tools.setExecutor(new CallToolExecutor(ctx));
  const shell = new Bash({ customCommands: [endCallCommand(defineCommand)] });
  const events = [];
  const session = {
    id: 'call-test', get seq() { return events.length; },
    append(type, data) {
      const event = { seq: events.length, type, data };
      events.push(event);
      recordSpokenAction(this, event);
      return event;
    },
  };
  const agent = { id: session.id, session };
  const scope = createScope(ctx, agent); agent.ctx = scope.ctx;
  t.after(() => { scope.rawDispose(); setCall(session.id, false, Date.now(), 'phone'); });
  let afterBody;
  tools.register(defineTool({
    name: 'bash', description: 'Run a command', parameters: { command: { type: 'string', required: true }, run_in_background: { type: 'boolean' } },
    output: { schema: { type: 'json' }, render: (_args, value) => [{ type: 'text', text: value.stdout || value.stderr }] },
    execute: async (args, exec) => {
      const { stdout, stderr, exitCode } = await shell.exec(args.command, { signal: exec.signal });
      afterBody?.();
      return { kind: args.run_in_background ? 'background' : 'foreground', stdout, stderr, exitCode };
    },
  }));
  const open = () => {
    setCall(session.id, true, Date.now(), 'phone');
    return liveCall(session.id).voice = { requestId: 'voice-call:phone:user', turn: 2 };
  };
  async function call(command = 'end-call', { spoken = 'Goodbye.', turn = 2, step = 1, background = false, signal = new AbortController().signal } = {}) {
    const block = { type: 'tool-call', id: 'tool-' + events.length, name: 'bash', arguments: JSON.stringify({ command, run_in_background: background }) };
    session.append('assistant/message', { turn, step, message: { content: [{ type: 'text', text: spoken }, block] } });
    return tools.execute({ agent, calls: [block], signal, log: { turn, step } });
  }
  return { call, open, events, scope, session, setAfterBody: fn => { afterBody = fn; } };
}

test('the actual foreground command concludes after its successful result and records the committed id', async t => {
  const { call, open, events } = await fixture(t);
  const voice = open();
  const result = await call();
  assert.equal(result.concluded, true);
  assert.deepEqual(voice.receipt, { step: 1, toolCallId: result.results[0].callId });
  assert.deepEqual(events.map(e => e.type), ['assistant/message', 'tool/call', 'tool/result']);
});

test('text, missing speech, background, an unrelated turn and expiry never issue a receipt', async t => {
  const { call, open, session } = await fixture(t);
  assert.equal((await call()).concluded, false);
  const voice = open();
  for (const [command, options] of [['echo end-call', {}], ['end-call', { spoken: ' ' }], ['end-call', { background: true }], ['end-call', { turn: 3 }]]) {
    assert.equal((await call(command, options)).concluded, false);
    assert.equal(voice.receipt, undefined);
  }
  setCall(session.id, true, Date.now() - LEASE_MS, 'phone');
  assert.equal((await call()).concluded, false);
  assert.equal(voice.receipt, undefined);
});

test('a late result after cancellation, policy rejection or redial cannot conclude the call', async t => {
  const { open, call, scope, session, setAfterBody } = await fixture(t);
  const cancelled = open(), ctrl = new AbortController();
  setAfterBody(() => ctrl.abort());
  assert.equal((await call('end-call', { signal: ctrl.signal })).concluded, false);
  assert.equal(cancelled.receipt, undefined);
  const replaced = open();
  setAfterBody(() => { setCall(session.id, false, Date.now(), 'phone'); setCall(session.id, true, Date.now(), 'other'); });
  assert.equal((await call()).concluded, false);
  assert.equal(replaced.receipt, undefined);
  setCall(session.id, false, Date.now(), 'other');
  setAfterBody(undefined);
  const denied = open();
  scope.ctx.on('tools/post-execute', () => ({ kind: 'block', feedback: [{ type: 'text', text: 'denied' }] }));
  const result = await call();
  assert.equal(result.results[0].result.isError, true);
  assert.equal(result.concluded, false);
  assert.equal(denied.receipt, undefined);
});

test('a single action can supply the actual farewell and task result as a literal, once', async t => {
  const { call, open } = await fixture(t);
  const voice = open();
  const result = await call('end-call --say "结果是 42。再见。"', { spoken: '' });
  assert.equal(result.concluded, true);
  const text = JSON.parse(result.results[0].result.content[0].text).farewell;
  assert.deepEqual(text, { callId: 'phone', requestId: voice.requestId, toolCallId: result.results[0].callId, text: '结果是 42。再见。' });
  for (const script of ['end-call --say ""', 'end-call --say "bye"; true', 'end-call --say "$HOME"', 'end-call --say farewell &']) {
    open();
    assert.equal((await call(script, { spoken: '' })).concluded, false);
  }
});
