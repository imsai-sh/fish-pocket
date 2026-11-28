import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import IosBotTopic from '../plugins/ios-bot-topic/index.mjs';

function fixture(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ios-bot-topic-'));
  const previous = process.env.DSH_IOS_DATA;
  process.env.DSH_IOS_DATA = dir;
  t.after(() => {
    if (previous === undefined) delete process.env.DSH_IOS_DATA;
    else process.env.DSH_IOS_DATA = previous;
    fs.rmSync(dir, { recursive: true, force: true });
  });
  const handlers = {}, deliveries = [], decisions = [];
  const member = { id: 'bot', sessionId: 'old', parts: ['earlier'], openParts: [] };
  const team = { bots: [member], readOnly: null };
  const input = { botId: member.id, sessionId: member.sessionId, requestId: randomUUID(), text: 'A new question', clientTimeZone: 'Asia/Shanghai' };
  const control = { other: [], failDelivery: false, switches: 0 };
  let route;
  const restored = [];
  const agent = {
    status: 'idle', session: { id: 'old' },
    inbox: { nextTurn: [], prepend: (target, message) => restored.unshift({ target, message }) },
    steer(message) {
      setImmediate(async () => {
        agent.status = 'running';
        const messages = [...control.other, message];
        const result = await handlers['agent/pre-step']({ agent, messages }, async () => ({ kind: 'enter', messages }));
        decisions.push(result);
        agent.status = 'idle';
        handlers['session/event'](agent.session, { type: 'turn/end' });
      });
    },
  };
  const peer = {};
  new IosBotTopic({
    effect: run => run(),
    on: (name, listener) => { handlers[name] = listener; },
    connection: {
      browserPeer: peer,
      fetch: { register: entry => { route = entry.fetch; } },
      createSharedFetchHandler: () => ({ fetch: async (req, principal) => {
        assert.equal(principal, peer);
        const { endpoint, payload } = await req.json();
        if (endpoint === 'state') return Response.json({ ok: true, value: team });
        assert.equal(endpoint, 'bot-new-part');
        assert.equal(payload.botId, member.id);
        assert.equal(agent.status, 'running', 'the idle ds-bot API would carry a handoff');
        member.openParts.push({ sessionId: member.sessionId, parts: member.parts });
        member.sessionId = 'fresh';
        member.parts = [];
        control.switches++;
        return Response.json({ ok: true, value: true });
      } }),
    },
    sessions: { get: () => null },
    sessionController: {
      resolveAgent: async () => ({ agent }),
      prompt: async request => {
        if (control.failDelivery) throw new Error('transport interrupted');
        deliveries.push(request);
      },
    },
  });
  const submit = (patch = {}) => route(new Request('http://localhost/api/ios-bot/new-topic', {
    method: 'POST', body: JSON.stringify({ ...input, ...patch }),
  }));
  return { submit, input, member, agent, team, control, deliveries, decisions, restored };
}

test('a new topic delivers the first user question once to an independent thread of the same Bot', async t => {
  const { submit, input, control, member, deliveries, decisions } = fixture(t);
  const responses = await Promise.all([submit(), submit()]);
  for (const result of responses) assert.deepEqual(await result.json(), { sessionId: 'fresh' });
  assert.equal((await submit()).status, 200);
  assert.equal(control.switches, 1);
  assert.deepEqual(member.parts, []);
  assert.deepEqual(decisions, [{ kind: 'enter', messages: [] }]);
  assert.deepEqual(deliveries, [{
    sessionId: 'fresh', requestId: input.requestId, mode: 'queue',
    content: [{ type: 'text', text: input.text }], clientTimeZone: input.clientTimeZone,
  }]);
  assert.equal((await submit({ text: 'Different input with the same ID' })).status, 409);
});

test('a retry after the switch resumes delivery to that thread without opening another', async t => {
  const { submit, control, deliveries } = fixture(t);
  control.failDelivery = true;
  assert.equal((await submit()).status, 409);
  control.failDelivery = false;
  assert.deepEqual(await (await submit()).json(), { sessionId: 'fresh' });
  assert.equal(control.switches, 1);
  assert.equal(deliveries.length, 1);
});

test('stale, busy, malformed and read-only requests cannot switch threads', async t => {
  const { submit, team, agent, control } = fixture(t);
  assert.equal((await submit({ requestId: '../invalid' })).status, 400);
  assert.equal((await submit({ sessionId: 'other' })).status, 409);
  team.readOnly = true;
  assert.equal((await submit()).status, 409);
  team.readOnly = null;
  agent.status = 'running';
  assert.equal((await submit()).status, 409);
  assert.equal(control.switches, 0);
});

test('queued input on a blocked Bot stays in the old thread while the new question gets a clean turn', async t => {
  const { submit, agent, control, decisions, deliveries, restored } = fixture(t);
  const steer = { id: 's', source: { kind: 'user' }, content: [{ type: 'text', text: 'interjection' }] };
  const queued = { id: 'q', source: { kind: 'user' }, content: [{ type: 'text', text: 'ordinary' }] };
  agent.inbox.nextTurn = [queued];
  control.other = [steer, queued];
  assert.deepEqual(await (await submit()).json(), { sessionId: 'fresh' });
  assert.deepEqual(decisions, [{ kind: 'enter', messages: [] }]);
  assert.deepEqual(restored, [{ target: 'next-step', message: steer }, { target: 'next-turn', message: queued }]);
  assert.equal(control.switches, 1);
  assert.deepEqual(deliveries[0].content, [{ type: 'text', text: 'A new question' }]);
});
