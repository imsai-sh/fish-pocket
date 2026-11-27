import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, test } from 'node:test';
import { setCall } from '../plugins/ios-call/index.mjs';
import IosVoiceMessage, {
  DEFAULT_GUIDANCE, MAX_CHARACTERS, TOOL, allowed, applySettings, describe, fromIm, resetSettings, settingsFile,
} from '../plugins/ios-voice-message/index.mjs';

/** A context that keeps the route and the tool registrations the plugin makes. */
function fakeContext() {
  const routes = new Map();
  const tools = [];
  const disposers = [];
  const ctx = {
    effect: (run) => { const dispose = run(); if (typeof dispose === 'function') disposers.push(dispose); },
    connection: { fetch: { register: (route) => { routes.set(route.path, route); return () => routes.delete(route.path); } } },
    tools: {
      register: (definition, options) => {
        const entry = { definition, options, live: true };
        tools.push(entry);
        return () => { entry.live = false; };
      },
    },
  };
  new IosVoiceMessage(ctx);
  return {
    routes,
    live: () => tools.filter((entry) => entry.live),
    dispose: () => disposers.forEach((d) => d()),
  };
}

const post = (routes, body) => routes.get('/api/ios-voice-message/settings').fetch(
  new Request('http://x/api/ios-voice-message/settings', { method: 'POST', body: typeof body === 'string' ? body : JSON.stringify(body) }),
);

/** A session whose log holds `messages` (user messages, `rpcId` on their source). */
function session(id, { messages = [], origin } = {}) {
  const events = messages.map((rpcId, index) => ({
    seq: index + 1,
    type: 'user/message',
    data: { id: `m${index}`, source: { kind: 'user', ...(rpcId === undefined ? {} : { rpcId }) } },
  }));
  return {
    id,
    header: origin === undefined ? {} : { origin },
    get seq() { return events.length; },
    snapshotEvents: (offset) => events.slice(offset),
    push(rpcId) { events.push({ seq: events.length + 1, type: 'user/message', data: { id: `m${events.length}`, source: { kind: 'user', rpcId } } }); },
  };
}

const base = { allowSessions: false, allowBots: true, ready: true, guidance: '', bots: ['bot'], groups: ['group', 'member'] };

let dispose = () => {};
afterEach(() => { dispose(); resetSettings(); });

test('nothing is offered before the app has sent its settings', () => {
  assert.equal(allowed({ session: session('bot') }), false);
});

test('the two switches decide: Bot chats and ordinary sessions apart', () => {
  applySettings(base);
  assert.equal(allowed({ session: session('bot') }), true);
  assert.equal(allowed({ session: session('s1') }), false);
  applySettings({ ...base, allowSessions: true, allowBots: false });
  assert.equal(allowed({ session: session('bot') }), false);
  assert.equal(allowed({ session: session('s1') }), true);
});

test('never in a group, a subagent, a call, or without a speech service', () => {
  applySettings({ ...base, allowSessions: true });
  assert.equal(allowed({ session: session('group') }), false);
  assert.equal(allowed({ session: session('member') }), false);
  assert.equal(allowed({ session: session('s1', { origin: 'subagent' }) }), false);
  setCall('s1', 'call1', true);
  assert.equal(allowed({ session: session('s1') }), false);
  setCall('s1', 'call1', false);
  assert.equal(allowed({ session: session('s1') }), true);
  applySettings({ ...base, allowSessions: true, ready: false });
  assert.equal(allowed({ session: session('s1') }), false);
});

test('a turn an IM chat started gets no voice message; the next one from the app does', () => {
  applySettings(base);
  const chat = session('bot', { messages: ['app-1', 'im:weixin:abc'] });
  assert.equal(fromIm(chat), true);
  assert.equal(allowed({ session: chat }), false);
  chat.push('app-2');
  assert.equal(allowed({ session: chat }), true);
  chat.push('im:telegram:def');
  assert.equal(allowed({ session: chat }), false);
});

test('messages queued through the inbox count too', () => {
  const events = [{ seq: 1, type: 'agent/inbox/spliced', data: { inserted: [{ source: { kind: 'user', rpcId: 'im:qq:1' } }] } }];
  const queued = { id: 'bot', header: {}, seq: 1, snapshotEvents: (offset) => events.slice(offset) };
  assert.equal(fromIm(queued), true);
});

test('the route takes the settings and re-registers the tool when the rule changes', async () => {
  const plugin = fakeContext();
  dispose = plugin.dispose;
  assert.equal(plugin.live().length, 1);
  assert.ok(plugin.live()[0].definition.description.endsWith(DEFAULT_GUIDANCE));

  const response = await post(plugin.routes, { ...base, guidance: '只在用户要求时发。' });
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { ok: true });
  const [tool] = plugin.live();
  assert.equal(tool.definition.name, TOOL);
  assert.match(tool.definition.description, /只在用户要求时发。$/);
  assert.equal(await tool.options.when({ agent: { session: session('bot') } }), true);

  await post(plugin.routes, { ...base, guidance: '只在用户要求时发。', allowBots: false });
  assert.equal(plugin.live().length, 1, 'same rule: the registration stays');
  assert.equal(await tool.options.when({ agent: { session: session('bot') } }), false);
});

test('a malformed request is refused and changes nothing', async () => {
  const plugin = fakeContext();
  dispose = plugin.dispose;
  for (const body of ['not json', {}, { ...base, bots: [1] }, { ...base, ready: 'yes' }]) {
    assert.equal((await post(plugin.routes, body)).status, 400);
  }
  assert.equal(allowed({ session: session('bot') }), false);
});

test('sending ends the turn; empty or overlong text is refused', async () => {
  const plugin = fakeContext();
  dispose = plugin.dispose;
  const { definition } = plugin.live()[0];
  let concluded = false;
  const value = await definition.execute({ text: ' 你好呀 ' }, { concludeTurn: () => { concluded = true; } });
  assert.deepEqual(value, { sent: true, characters: 3 });
  assert.equal(concluded, true);
  await assert.rejects(definition.execute({ text: '  ' }, {}), /empty/);
  await assert.rejects(definition.execute({ text: '啊'.repeat(MAX_CHARACTERS + 1) }, {}), /too long/);
});

test('the description says how to write it and ends on the user rule', () => {
  const text = describe('我的规则');
  assert.match(text, /ends your turn/);
  assert.match(text, /without Markdown/);
  assert.ok(text.endsWith('我的规则'));
  assert.ok(describe('   ').endsWith(DEFAULT_GUIDANCE));
});

test('what the app sent survives an engine restart', async () => {
  const data = fs.mkdtempSync(path.join(os.tmpdir(), 'voice-message-'));
  const previous = process.env.DSH_IOS_DATA;
  process.env.DSH_IOS_DATA = data;
  try {
    const first = fakeContext();
    await post(first.routes, { ...base, guidance: '只在用户要求时发。' });
    assert.ok(fs.existsSync(settingsFile(data)));
    first.dispose();
    assert.equal(allowed({ session: session('bot') }), false, 'the restart forgets what is in memory');

    // The new engine reads it back before the app says anything.
    const second = fakeContext();
    dispose = second.dispose;
    assert.equal(allowed({ session: session('bot') }), true);
    assert.ok(second.live()[0].definition.description.endsWith('只在用户要求时发。'));
  } finally {
    if (previous === undefined) delete process.env.DSH_IOS_DATA; else process.env.DSH_IOS_DATA = previous;
    fs.rmSync(data, { recursive: true, force: true });
  }
});

test('an unreadable file is ignored', () => {
  const data = fs.mkdtempSync(path.join(os.tmpdir(), 'voice-message-'));
  fs.writeFileSync(settingsFile(data), '{not json');
  const previous = process.env.DSH_IOS_DATA;
  process.env.DSH_IOS_DATA = data;
  try {
    const plugin = fakeContext();
    dispose = plugin.dispose;
    assert.equal(allowed({ session: session('bot') }), false);
  } finally {
    if (previous === undefined) delete process.env.DSH_IOS_DATA; else process.env.DSH_IOS_DATA = previous;
    fs.rmSync(data, { recursive: true, force: true });
  }
});
