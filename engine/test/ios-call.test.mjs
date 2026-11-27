import assert from 'node:assert/strict';
import { afterEach, test } from 'node:test';
import IosCall, { LEASE_MS, NOTE, SOURCE, onCall, setCall } from '../plugins/ios-call/index.mjs';

/** A context that keeps the routes and the pre-step handler the plugin registers. */
function fakeContext() {
  const routes = new Map();
  const handlers = new Map();
  const disposers = [];
  const ctx = {
    effect: (run) => { const dispose = run(); if (typeof dispose === 'function') disposers.push(dispose); },
    on: (name, handler) => { handlers.set(name, handler); },
    connection: { fetch: { register: (route) => { routes.set(route.path, route); return () => routes.delete(route.path); } } },
  };
  new IosCall(ctx);
  return { routes, preStep: handlers.get('agent/pre-step'), dispose: () => disposers.forEach((d) => d()) };
}

const state = (routes, body) => routes.get('/api/ios-call/state').fetch(
  new Request('http://x/api/ios-call/state', { method: 'POST', body: typeof body === 'string' ? body : JSON.stringify(body) }),
);

/** One pre-step pass for `sessionId` with the given proposal. */
const step = (preStep, sessionId, { number = 1, messages = [{ role: 'user', content: [] }], kind = 'proceed', aborted = false } = {}) =>
  preStep(
    { agent: { session: { id: sessionId } }, step: number, signal: { aborted } },
    async () => ({ kind, messages }),
  );

let dispose = () => {};
afterEach(() => dispose());

test('a session on a call gets the note after its messages, of its own source kind', async () => {
  const plugin = fakeContext();
  dispose = plugin.dispose;
  const response = await state(plugin.routes, { sessionId: 's1', active: true });
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { ok: true });

  const proposed = [{ role: 'user', content: [{ type: 'text', text: '你好' }] }];
  const decision = await step(plugin.preStep, 's1', { messages: proposed });
  assert.equal(decision.messages.length, 2);
  assert.equal(decision.messages[0], proposed[0]);
  const note = decision.messages[1];
  assert.equal(note.role, 'user');
  assert.equal(note.source.kind, SOURCE);
  assert.equal(note.content[0].text, NOTE);
});

test('other sessions, later steps, retries and rejections are left alone', async () => {
  const plugin = fakeContext();
  dispose = plugin.dispose;
  await state(plugin.routes, { sessionId: 's1', active: true });
  assert.equal((await step(plugin.preStep, 's2')).messages.length, 1);
  assert.equal((await step(plugin.preStep, 's1', { number: 2 })).messages.length, 1);
  assert.equal((await step(plugin.preStep, 's1', { messages: [] })).messages.length, 0);
  assert.equal((await step(plugin.preStep, 's1', { kind: 'reject' })).messages.length, 1);
  assert.equal((await step(plugin.preStep, 's1', { aborted: true })).messages.length, 1);
});

test('hanging up ends the note at once', async () => {
  const plugin = fakeContext();
  dispose = plugin.dispose;
  await state(plugin.routes, { sessionId: 's1', active: true });
  await state(plugin.routes, { sessionId: 's1', active: false });
  assert.equal((await step(plugin.preStep, 's1')).messages.length, 1);
});

test('a call the app stopped renewing lapses', () => {
  setCall('s3', true, 1_000);
  assert.equal(onCall('s3', 1_000 + LEASE_MS - 1), true);
  setCall('s3', true, 50_000);
  assert.equal(onCall('s3', 1_000 + LEASE_MS + 1), true, 'renewing moves the lapse');
  assert.equal(onCall('s3', 50_000 + LEASE_MS), false);
  assert.equal(onCall('s3', 0), false, 'a lapsed call is forgotten');
});

test('a malformed request is refused', async () => {
  const plugin = fakeContext();
  dispose = plugin.dispose;
  assert.equal((await state(plugin.routes, 'not json')).status, 400);
  assert.equal((await state(plugin.routes, { sessionId: '', active: true })).status, 400);
  assert.equal((await state(plugin.routes, { sessionId: 's1' })).status, 400);
});

test('the fixed action is offered only to a genuine voice request belonging to this call', async () => {
  const plugin = fakeContext();
  dispose = plugin.dispose;
  await state(plugin.routes, { sessionId: 'one', active: true, callId: 'current', revision: 1 });
  const enter = (id, kind = 'user') => plugin.preStep({
    agent: { session: { id: 'one', seq: 12 } }, turn: 4, step: 1, signal: new AbortController().signal,
  }, async () => ({ kind: 'enter', messages: [{ source: { kind, rpcId: id } }] }));
  assert.match((await enter('voice-call:current:new')).messages.at(-1).content[0].text, /end-call/);
  const { liveCall } = await import('../plugins/ios-call/index.mjs');
  assert.equal(liveCall('one').voice.requestId, 'voice-call:current:new');
  await plugin.preStep({ agent: { session: { id: 'one' } }, turn: 4, step: 2 }, async () => ({
    kind: 'enter', messages: [{ source: { kind: 'user', rpcId: 'steer' } }],
  }));
  assert.equal(liveCall('one').voice, undefined);
  assert.doesNotMatch((await enter('voice-call:old:new')).messages.at(-1).content[0].text, /end-call/);
  assert.doesNotMatch((await enter('voice-call:current:new', 'schedule')).messages.at(-1).content[0].text, /end-call/);
  assert.doesNotMatch((await enter('text-message')).messages.at(-1).content[0].text, /end-call/);
});

test('late reports and confirmation queries cannot move a farewell to another turn or call', async () => {
  const plugin = fakeContext();
  dispose = plugin.dispose;
  const update = (callId, revision, active) => state(plugin.routes, { sessionId: 'ordinary', callId, revision, active });
  const query = async data => (await (await plugin.routes.get('/api/ios-call/farewell').fetch(
    new Request('http://x/api/ios-call/farewell', { method: 'POST', body: JSON.stringify(data) }),
  )).json()).confirmed;
  const { liveCall } = await import('../plugins/ios-call/index.mjs');
  await update('first', 1, true);
  const receipt = { sessionId: 'ordinary', callId: 'first', turn: 2, step: 1, requestId: 'speech', toolCallId: 'tool-one' };
  liveCall('ordinary').voice = { turn: 2, requestId: 'speech', receipt: { step: 1, toolCallId: 'tool-one' } };
  assert.equal(await query(receipt), true);
  assert.equal(await query({ ...receipt, turn: 3 }), false);
  assert.equal(await query({ ...receipt, toolCallId: 'forged' }), false);
  await update('second', 4, true);
  await update('first', 3, false);
  await update('first', 2, true);
  assert.equal(liveCall('ordinary').id, 'second');
  assert.equal(await query(receipt), false);
  assert.equal(await query({ ...receipt, callId: 'second' }), false);
  await update('second', 5, false);
  assert.equal(await query(receipt), false);
});
