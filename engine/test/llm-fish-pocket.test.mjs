import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { Context } from '@deepseek-ai/cordis';
import FishPocket, { DEFAULT_KEY_REF, PROVIDER, resolveOptions } from '../plugins/llm-fish-pocket/index.mjs';

const KEY = `fpk_${'a'.repeat(43)}`;

/** Mount the route with a fake llm registry and credential store. */
async function mount(config, credentials) {
  const ctx = new Context();
  let adapter;
  ctx.provide('llm');
  ctx.provide('credentials');
  ctx.set('llm', {
    registerAdapter(providers, registered) {
      assert.deepEqual(providers, [PROVIDER]);
      adapter = registered;
      return { replace() {}, dispose() {} };
    },
  });
  ctx.set('credentials', {
    resolve: async (ref) => (credentials.has(ref) ? { value: credentials.get(ref) } : undefined),
  });
  ctx.plugin(FishPocket, config);
  await new Promise((done) => setTimeout(done, 20));
  assert.ok(adapter, 'route registered an adapter');
  return adapter;
}

/** A stand-in gateway that records requests and answers one SSE turn. */
async function gateway(status = 200) {
  const requests = [];
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', (chunk) => (body += chunk));
    req.on('end', () => {
      requests.push({ url: req.url, headers: req.headers, body });
      if (status !== 200) {
        res.writeHead(status, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ type: 'error', error: { type: 'insufficient_balance', message: 'Fish Pocket 余额不足' } }));
        return;
      }
      res.writeHead(200, { 'content-type': 'text/event-stream' });
      const events = [
        { type: 'message_start', message: { id: 'msg_1', type: 'message', role: 'assistant', model: 'deepseek-flash', content: [], usage: { input_tokens: 3, output_tokens: 1 } } },
        { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } },
        { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'hello' } },
        { type: 'content_block_stop', index: 0 },
        { type: 'message_delta', delta: { stop_reason: 'end_turn' }, usage: { output_tokens: 2 } },
        { type: 'message_stop' },
      ];
      res.end(events.map((e) => `event: ${e.type}\ndata: ${JSON.stringify(e)}\n\n`).join(''));
    });
  });
  await new Promise((done) => server.listen(0, '127.0.0.1', done));
  const { port } = server.address();
  return { requests, baseURL: `http://127.0.0.1:${port}/anthropic`, close: () => server.close() };
}

const userTurn = { role: 'user', content: [{ type: 'text', text: 'hi' }] };

test('without a configured gateway the route offers nothing', async () => {
  assert.equal(resolveOptions(FishPocket.Config({})), null);
  const adapter = await mount({}, new Map([[DEFAULT_KEY_REF, KEY]]));
  assert.deepEqual(await adapter.listModels(PROVIDER), []);
});

test('the route never falls back to $DEEPSEEK_BASE_URL', async () => {
  const saved = process.env.DEEPSEEK_BASE_URL;
  process.env.DEEPSEEK_BASE_URL = 'https://elsewhere.example/anthropic';
  try {
    assert.equal(resolveOptions(FishPocket.Config({})), null);
  } finally {
    if (saved === undefined) delete process.env.DEEPSEEK_BASE_URL;
    else process.env.DEEPSEEK_BASE_URL = saved;
  }
});

test('models appear only once the user is signed in', async () => {
  const credentials = new Map();
  const adapter = await mount({ baseURL: 'https://api.example.test/anthropic' }, credentials);
  assert.deepEqual(await adapter.listModels(PROVIDER), []);
  credentials.set(DEFAULT_KEY_REF, KEY);
  const ids = (await adapter.listModels(PROVIDER)).map((model) => model.id);
  assert.deepEqual(ids, ['deepseek-flash', 'deepseek-v4-pro']);
});

test('requests go to the gateway with the runtime key', async () => {
  const server = await gateway();
  try {
    const adapter = await mount({ baseURL: server.baseURL }, new Map([[DEFAULT_KEY_REF, KEY]]));
    const call = await adapter.prepareCall(PROVIDER, 'deepseek-flash');
    const events = [];
    for await (const event of call.stream({ provider: PROVIDER, model: 'deepseek-flash', messages: [userTurn], tools: [] })) {
      events.push(event);
    }
    assert.equal(server.requests.length, 1);
    const [request] = server.requests;
    assert.equal(request.url, '/anthropic/v1/messages');
    assert.equal(request.headers['x-api-key'], KEY);
    assert.equal(JSON.parse(request.body).model, 'deepseek-flash');
    assert.ok(JSON.stringify(events).includes('hello'), 'streamed text reaches the harness');
  } finally {
    server.close();
  }
});

test('a 402 from the gateway surfaces as QUOTA', async () => {
  const server = await gateway(402);
  try {
    const adapter = await mount({ baseURL: server.baseURL }, new Map([[DEFAULT_KEY_REF, KEY]]));
    const call = await adapter.prepareCall(PROVIDER, 'deepseek-flash');
    await assert.rejects(async () => {
      for await (const _ of call.stream({ provider: PROVIDER, model: 'deepseek-flash', messages: [userTurn], tools: [] }));
    }, (error) => error.code === 'QUOTA');
  } finally {
    server.close();
  }
});

test('signed out: a call fails with MISSING_CREDENTIAL before any request', async () => {
  const server = await gateway();
  try {
    const adapter = await mount({ baseURL: server.baseURL }, new Map());
    const call = await adapter.prepareCall(PROVIDER, 'deepseek-flash');
    await assert.rejects(async () => {
      for await (const _ of call.stream({ provider: PROVIDER, model: 'deepseek-flash', messages: [userTurn], tools: [] }));
    }, (error) => error.code === 'MISSING_CREDENTIAL');
    assert.equal(server.requests.length, 0);
  } finally {
    server.close();
  }
});
