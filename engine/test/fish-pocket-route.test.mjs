// The `fish-pocket` model route (ios.patch.yml): a profile on the stock pi-ai
// entry, OpenAI Chat Completions to the Fish Pocket gateway. Loaded here from the
// overlay itself, as the engine reads it, and driven against a local server
// standing in for the gateway.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { Context } from '@deepseek-ai/cordis';
import { interpolate } from '@deepseek-ai/cordis-plugin-loader';
import { entryListSchema } from '@deepseek-ai/cordis-plugin-include';
import * as PiAi from '@deepseek-ai/dsh-llm-pi-ai';

const require = createRequire(import.meta.url);
const yaml = require(require.resolve('js-yaml', { paths: [require.resolve('@deepseek-ai/cordis-plugin-include')] }));
const overlay = yaml.load(fs.readFileSync(fileURLToPath(new URL('../ios.patch.yml', import.meta.url)), 'utf8'), { schema: entryListSchema });
const entry = overlay.find((item) => item.id === 'llm-pi-ai');
const KEY = `fpk_${'a'.repeat(43)}`;
const REF = 'FISH_POCKET_RUNTIME_KEY';

/** The entry as the loader resolves it with FISH_POCKET_API_URL set to `api`. */
function resolved(api) {
  const saved = process.env.FISH_POCKET_API_URL;
  if (api === undefined) delete process.env.FISH_POCKET_API_URL;
  else process.env.FISH_POCKET_API_URL = api;
  try {
    return { config: interpolate({}, entry.config) };
  } finally {
    if (saved === undefined) delete process.env.FISH_POCKET_API_URL;
    else process.env.FISH_POCKET_API_URL = saved;
  }
}

async function mount(config, credentials) {
  const ctx = new Context();
  let adapter;
  ctx.provide('llm');
  ctx.provide('credentials');
  ctx.set('llm', {
    registerAdapter(routes, registered) {
      assert.deepEqual(routes, ['fish-pocket']);
      adapter = registered;
      return { replace() {}, dispose() {} };
    },
    registerConfigurableProviders: () => ({ replace() {}, dispose() {} }),
    registerModelDiscovery: () => () => {},
  });
  ctx.set('credentials', {
    resolve: async (ref) => (credentials.has(ref) ? { value: credentials.get(ref), source: 'store' } : undefined),
  });
  ctx.plugin(PiAi, config);
  await new Promise((done) => setTimeout(done, 30));
  assert.ok(adapter, 'route registered');
  return adapter;
}

/** A stand-in gateway: records requests, answers one streamed turn or an error. */
async function gateway(status = 200) {
  const requests = [];
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', (chunk) => (body += chunk));
    req.on('end', () => {
      requests.push({ url: req.url, headers: req.headers, body: JSON.parse(body) });
      if (status !== 200) {
        res.writeHead(status, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: { message: 'Fish Pocket 余额不足，请充值后继续。(insufficient balance)', type: 'insufficient_balance', code: 'insufficient_balance' } }));
        return;
      }
      res.writeHead(200, { 'content-type': 'text/event-stream' });
      const chunks = [
        { choices: [{ index: 0, delta: { role: 'assistant', reasoning_content: 'thinking…' } }] },
        { choices: [{ index: 0, delta: { content: 'hello' } }] },
        { choices: [{ index: 0, delta: {}, finish_reason: 'stop' }] },
        { choices: [], usage: { prompt_tokens: 5, completion_tokens: 3, total_tokens: 8 } },
      ];
      res.end(chunks.map((c) => `data: ${JSON.stringify({ id: 'c1', object: 'chat.completion.chunk', model: 'deepseek-flash', ...c })}\n\n`).join('') + 'data: [DONE]\n\n');
    });
  });
  await new Promise((done) => server.listen(0, '127.0.0.1', done));
  return { requests, api: `http://127.0.0.1:${server.address().port}`, close: () => server.close() };
}

const turn = (reasoningEffort) => ({
  provider: 'fish-pocket',
  model: 'deepseek-flash',
  messages: [{ role: 'user', content: [{ type: 'text', text: 'hi' }] }],
  tools: [],
  ...(reasoningEffort ? { reasoningEffort } : {}),
});

async function run(adapter, options) {
  const call = await adapter.prepareCall('fish-pocket', 'deepseek-flash');
  const events = [];
  for await (const event of call.stream(options)) events.push(event);
  return events;
}

test('the route points at FISH_POCKET_API_URL, and nowhere without it', () => {
  assert.equal(resolved('https://api.example.test/').config.providers['fish-pocket'].baseURL, 'https://api.example.test/v1');
  assert.equal(new URL(resolved(undefined).config.providers['fish-pocket'].baseURL).hostname, 'fish-pocket.invalid');
  // Only the Fish Pocket profile: user profiles live in the settings document.
  assert.deepEqual(Object.keys(resolved(undefined).config.providers), ['fish-pocket']);
});

test('models appear only once the runtime key is stored', async () => {
  const credentials = new Map();
  const adapter = await mount(resolved('https://api.example.test').config, credentials);
  assert.deepEqual(await adapter.listModels('fish-pocket'), []);
  credentials.set(REF, KEY);
  assert.deepEqual((await adapter.listModels('fish-pocket')).map((m) => m.id), ['deepseek-flash']);
});

test('chat completions go to the gateway with the runtime key and DeepSeek thinking switches', async () => {
  const server = await gateway();
  try {
    const adapter = await mount(resolved(server.api).config, new Map([[REF, KEY]]));
    const events = await run(adapter, turn('high'));
    await run(adapter, turn('off'));
    const [thinking, plain] = server.requests;
    assert.equal(thinking.url, '/v1/chat/completions');
    assert.equal(thinking.headers.authorization, `Bearer ${KEY}`);
    assert.equal(thinking.body.model, 'deepseek-flash');
    assert.equal(thinking.body.stream, true);
    assert.deepEqual(thinking.body.stream_options, { include_usage: true });
    assert.deepEqual(thinking.body.thinking, { type: 'enabled' });
    assert.ok('max_tokens' in thinking.body && !('max_completion_tokens' in thinking.body));
    assert.ok(!('store' in thinking.body));
    assert.deepEqual(plain.body.thinking, { type: 'disabled' });
    assert.ok(JSON.stringify(events).includes('hello'), 'answer reaches the harness');
  } finally {
    server.close();
  }
});

test('a 402 from the gateway ends the turn with QUOTA', async () => {
  const server = await gateway(402);
  try {
    const adapter = await mount(resolved(server.api).config, new Map([[REF, KEY]]));
    const finish = (await run(adapter, turn('off'))).find((event) => event.type === 'finish');
    assert.equal(finish.reason.kind, 'error');
    assert.equal(finish.reason.failure.code, 'QUOTA');
    // The app tells Fish Pocket's refusals apart by this name in the message.
    assert.match(finish.reason.failure.message, /Fish Pocket/);
  } finally {
    server.close();
  }
});
