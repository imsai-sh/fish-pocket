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

const post = (routes, path, body) => routes.get(`/api/ios-call/${path}`).fetch(
  new Request(`http://x/api/ios-call/${path}`, { method: 'POST', body: typeof body === 'string' ? body : JSON.stringify(body) }),
);
const state = (routes, body) => post(routes, 'state', body);
const said = (routes, body) => post(routes, 'said', body);

async function dial(routes, sessionId, callId) {
  const response = await state(routes, { sessionId, callId, active: true });
  assert.equal(response.status, 200);
  const { ok, leaseId } = await response.json();
  assert.equal(ok, true);
  assert.ok(leaseId);
  return leaseId;
}

const user = (rpcId, text) => ({
  role: 'user', source: { kind: 'user', rpcId }, content: [{ type: 'text', text }],
});

/** One pre-step pass for `sessionId` with the given proposal. */
const step = (preStep, sessionId, { number = 1, messages = [user('typed', '你好')], kind = 'proceed', aborted = false } = {}) =>
  preStep(
    { agent: { session: { id: sessionId } }, step: number, signal: { aborted } },
    async () => ({ kind, messages }),
  );

let dispose = () => {};
afterEach(() => dispose());

test('a session on a call gets the note after its messages, of its own source kind', async () => {
  const plugin = fakeContext();
  dispose = plugin.dispose;
  await dial(plugin.routes, 's1', 'call1');

  const proposed = [user('spoken', '你好')];
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
  await dial(plugin.routes, 's1', 'call1');
  assert.equal((await step(plugin.preStep, 's2')).messages.length, 1);
  assert.equal((await step(plugin.preStep, 's1', { number: 2 })).messages.length, 1);
  assert.equal((await step(plugin.preStep, 's1', { messages: [] })).messages.length, 0);
  assert.equal((await step(plugin.preStep, 's1', { kind: 'reject' })).messages.length, 1);
  assert.equal((await step(plugin.preStep, 's1', { aborted: true })).messages.length, 1);
});

test('hanging up ends the note at once', async () => {
  const plugin = fakeContext();
  dispose = plugin.dispose;
  await dial(plugin.routes, 's1', 'call1');
  await state(plugin.routes, { sessionId: 's1', callId: 'call1', active: false });
  assert.equal((await step(plugin.preStep, 's1')).messages.length, 1);
});

test('a call the app stopped renewing lapses', () => {
  setCall('s3', 'call3', true, 1_000);
  assert.equal(onCall('s3', 1_000 + LEASE_MS - 1), true);
  setCall('s3', 'call3', true, 50_000);
  assert.equal(onCall('s3', 1_000 + LEASE_MS + 1), true, 'renewing moves the lapse');
  assert.equal(onCall('s3', 50_000 + LEASE_MS), false);
  assert.equal(onCall('s3', 0), false, 'a lapsed call is forgotten');
});

test('a malformed request is refused', async () => {
  const plugin = fakeContext();
  dispose = plugin.dispose;
  assert.equal((await state(plugin.routes, 'not json')).status, 400);
  assert.equal((await state(plugin.routes, { sessionId: '', callId: 'call1', active: true })).status, 400);
  assert.equal((await state(plugin.routes, { sessionId: 's1', active: true })).status, 400);
  assert.equal((await state(plugin.routes, { sessionId: 's1', callId: 'call1' })).status, 400);
  assert.equal((await said(plugin.routes, 'not json')).status, 400);
  const reminder = { sessionId: 's1', leaseId: 'lease1', requestId: 'spoken', text: '  ' };
  assert.equal((await said(plugin.routes, reminder)).status, 400);
  assert.equal((await said(plugin.routes, { ...reminder, text: 'a'.repeat(501) })).status, 400);
  assert.equal((await said(plugin.routes, { ...reminder, requestId: '', text: '还在吗？' })).status, 400);
});

test('a localized reminder precedes its exact spoken reply once, even with other input already queued', async () => {
  const { routes, preStep, dispose: cleanup } = fakeContext();
  dispose = cleanup;
  const leaseId = await dial(routes, 's1', 'call1');
  await dial(routes, 'bot', 'call2');
  const text = '還在嗎？沒聲音的話我先掛了';
  const reminder = { sessionId: 's1', leaseId, requestId: 'spoken', text };
  assert.equal((await said(routes, reminder)).status, 200);

  const reply = user('spoken', '在');
  const messages = [reply];
  const typed = user('typed', '继续');
  assert.deepEqual((await step(preStep, 's1', { messages: [typed] })).messages.map((m) => m.source.kind), ['user', SOURCE]);
  assert.deepEqual((await step(preStep, 'bot', { messages })).messages.map((m) => m.source.kind), ['user', SOURCE]);
  assert.deepEqual((await step(preStep, 's1', { number: 2, messages })).messages, messages);
  assert.deepEqual((await step(preStep, 's1', { kind: 'reject', messages })).messages, messages);
  assert.deepEqual((await step(preStep, 's1', { aborted: true, messages })).messages, messages);
  const retry = { ...reply, source: { kind: 'retry', rpcId: 'spoken' }, content: [] };
  assert.deepEqual((await step(preStep, 's1', { messages: [retry] })).messages.map((m) => m.source.kind), ['retry', SOURCE]);

  const decision = await step(preStep, 's1', { messages: [typed, reply] });
  assert.deepEqual(decision.messages.map((m) => m.source.kind), ['user', 'voice-call-said', 'user', SOURCE]);
  assert.equal(decision.messages[0], typed);
  assert.equal(decision.messages[2], reply);
  const hidden = decision.messages[1];
  assert.equal(hidden.role, 'user');
  assert.ok(hidden.content[0].text.includes(text));
  assert.deepEqual(hidden.source.sections, [{ name: 'voice-call-said', text: hidden.content[0].text }]);

  // A repeated report or pre-step pass cannot add the reminder again.
  assert.equal((await said(routes, reminder)).status, 200);
  assert.deepEqual((await step(preStep, 's1', { messages })).messages.map((m) => m.source.kind), ['user', SOURCE]);
});

test('expiry and renewal of a lapsed call discard old and late reminders', async (t) => {
  t.mock.timers.enable({ apis: ['Date'], now: 1_000 });
  const { routes, preStep, dispose: cleanup } = fakeContext();
  dispose = cleanup;
  const leaseId = await dial(routes, 's1', 'call1');
  const reminder = { sessionId: 's1', leaseId, requestId: 'spoken', text: '还在吗？' };
  await said(routes, reminder);

  t.mock.timers.tick(LEASE_MS / 2);
  assert.equal(await dial(routes, 's1', 'call1'), leaseId);
  t.mock.timers.tick(LEASE_MS);
  const renewed = await dial(routes, 's1', 'call1');
  assert.notEqual(renewed, leaseId);
  // Renewal itself has to discard a lease that nobody already looked up as expired.
  await said(routes, reminder);
  const messages = [user('spoken', '在')];
  assert.deepEqual((await step(preStep, 's1', { messages })).messages.map((m) => m.source.kind), ['user', SOURCE]);
});

test('hanging up clears the reminder and a late report cannot follow a redial', async () => {
  const { routes, preStep, dispose: cleanup } = fakeContext();
  dispose = cleanup;
  const leaseId = await dial(routes, 's1', 'call1');
  const reminder = { sessionId: 's1', leaseId, requestId: 'spoken', text: '还在吗？' };
  const messages = [user('spoken', '在')];
  await said(routes, reminder);
  await state(routes, { sessionId: 's1', callId: 'call1', active: false });
  await said(routes, reminder);
  assert.deepEqual((await step(preStep, 's1', { messages })).messages, messages);

  const redial = await dial(routes, 's1', 'call2');
  assert.notEqual(redial, leaseId);
  await said(routes, reminder);
  await state(routes, { sessionId: 's1', callId: 'call1', active: false });
  assert.deepEqual((await step(preStep, 's1', { messages })).messages.map((m) => m.source.kind), ['user', SOURCE]);
  await said(routes, { ...reminder, leaseId: redial });
  assert.deepEqual((await step(preStep, 's1', { messages })).messages.map((m) => m.source.kind), ['voice-call-said', 'user', SOURCE]);
});
