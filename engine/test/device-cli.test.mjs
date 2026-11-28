import test from 'node:test';
import assert from 'node:assert/strict';
import { Context } from '@deepseek-ai/cordis';
import { createScope } from '@deepseek-ai/dsh-scope';
import { SystemPrompt } from '@deepseek-ai/dsh-system-prompt';
import ToolsService, { defineTool } from '@deepseek-ai/dsh-tools';
import * as nativeExecutor from '@deepseek-ai/dsh-tool-executor-native';
import { registerDeviceTools, invokeDeviceTool } from '../plugins/ios-native/cli.mjs';
import { TOOLS } from '../plugins/ios-native/tools.mjs';
import { withActionCaller } from '../runtime/action-command.mjs';
import { deviceCommand, parseDeviceCommand } from '../runtime/device-cli.mjs';
import { browserCommand } from '../runtime/browser-cli.mjs';

const signal = new AbortController().signal;
const command = deviceCommand((_name, run) => run);
const definitions = Object.values(TOOLS).filter(def => typeof def !== 'function');
const fixture = (name, execute = (_args, { agent }) => agent.id) => defineTool({
  name, description: 'Read a ' + name + ' record.', parameters: {},
  output: { schema: { type: 'string' }, render: (_args, text) => [{ type: 'text', text }] }, execute,
});

async function setup(t) {
  const ctx = new Context();
  await ctx.plugin(SystemPrompt, {});
  await ctx.plugin(ToolsService, {});
  await ctx.plugin(nativeExecutor);
  const agents = new Map();
  ctx.provide('agents');
  ctx.provide('attachments');
  ctx.set('agents', { get: id => agents.get(id) });
  ctx.set('attachments', { imageHostPath: () => undefined });
  const modelSelection = { provider: 'local', model: 'fixture' };
  const makeAgent = id => {
    const agent = { id, model: { current: () => modelSelection } };
    const scope = createScope(ctx, agent);
    agent.ctx = scope.ctx;
    t.after(() => scope.rawDispose());
    agents.set(id, agent);
    return agent;
  };
  const tools = ctx.get('tools');
  const resolve = agent => tools.resolve({ agent, modelSelection, signal });
  const run = (agent, argv) => withActionCaller({ agent, agents, tools, signal }, () => command(argv, { signal }));
  return { ctx, tools, makeAgent, resolve, run };
}

test('device CLI accepts every original device action and its native schema types', () => {
  const parse = (...argv) => parseDeviceCommand(argv, definitions);
  assert.ok(definitions.some(definition => definition.name === 'notify'));
  for (const def of definitions) {
    assert.ok(parse('--help').help.includes(def.name));
    assert.match(parse(def.name, '--help').help, /\S/);
    const { action, ...params } = def.parameters.properties;
    const flags = (def.parameters.required ?? []).filter(k => k !== 'action').flatMap(k => ['--' + k, 'sample']);
    for (const op of action?.enum ?? [undefined]) {
      const result = parse(def.name, ...(op ? [op] : []), ...flags);
      assert.equal(result.name, def.name);
      assert.equal(result.args.action, op);
      assert.equal(Object.keys(result.args).length, (op ? 1 : 0) + flags.length / 2);
    }
    assert.ok(!Object.hasOwn(params, 'session'));
  }
  assert.deepEqual(parse('notify', 'schedule', '--after-seconds', '1200', '--body', '喝水').args,
    { action: 'schedule', afterSeconds: 1200, body: '喝水' });
  assert.deepEqual(parse('photos', 'favorite', '--ids', '["first","second"]', '--value', 'false').args,
    { action: 'favorite', ids: ['first', 'second'], value: false });
  assert.deepEqual(parse('alarm', 'create', '--repeat-weekdays', '[2,4]').args.repeatWeekdays, [2, 4]);
  assert.deepEqual(parse('open_url', 'https://example.org').args, { url: 'https://example.org' });
  assert.throws(() => parse('notify', 'schedule', '--after-seconds', 'NaN'), /number/);
  assert.throws(() => parse('photos', 'favorite', '--ids', '{}'), /JSON array/);
  assert.throws(() => parse('calendar', 'list', '--session', 'other'), /Unexpected/);
  assert.throws(() => parse('bash', '--help'), /unavailable/);
});

test('first and fifth device calls and a restored agent keep the original model tool set', async t => {
  const { ctx, tools, makeAgent, resolve, run } = await setup(t);
  const a = makeAgent('a'), b = makeAgent('b');
  for (const name of ['bash', 'mcp__fixture__lookup', 'generate_image']) tools.register(fixture(name));
  const names = ['calendar', 'photos', 'reminders', 'location', 'weather'];
  registerDeviceTools(ctx, names.map(name => fixture(name)));
  const snapshot = async agent => {
    const step = await resolve(agent);
    try { return tools.definitions(agent, step).map(d => [d.name, d.description, d.parameters]); }
    finally { step.dispose(); }
  };
  const original = await snapshot(a);
  assert.deepEqual(original.map(([name]) => name).sort(), ['bash', 'generate_image', 'mcp__fixture__lookup']);
  for (const name of names) {
    assert.equal((await run(a, [name])).stdout, 'a\n');
    assert.deepEqual(await snapshot(a), original);
  }
  const restored = makeAgent('a');
  assert.deepEqual(await snapshot(restored), original);
  assert.deepEqual((await Promise.all([run(restored, ['calendar']), run(b, ['calendar'])])).map(r => r.stdout), ['a\n', 'b\n']);
  assert.equal((await run(a, ['calendar'])).exitCode, 1);
  restored.ctx.get('tools').guard(({ name }) => name === 'calendar' ? 'User refused calendar' : undefined);
  assert.match((await run(restored, ['calendar'])).stderr, /User refused calendar/);
  b.ctx.get('tools').restrict({ deny: ['photos'] });
  assert.doesNotMatch((await run(b, ['--help'])).stdout, /photos/);
  assert.match((await run(b, ['photos'])).stderr, /unavailable/);
  b.ctx.get('tools').register(fixture('weather'));
  await assert.rejects(invokeDeviceTool(tools, b, 'weather', {}, signal), /unavailable/);
});

test('a foreground bash screenshot returns the approved image on the outer tool result', async t => {
  const { ctx, tools, makeAgent, resolve } = await setup(t);
  const agent = makeAgent('screenshot');
  const image = { attachmentId: 'image-id', bytes: 10, mediaType: 'image/jpeg', width: 2, height: 2 };
  const browser = defineTool({
    name: 'browser', description: 'Screenshot', parameters: { action: { type: 'string', required: true } },
    output: { schema: { type: 'string' }, render: () => [{ type: 'image', attachment: image }] },
    execute: () => 'captured',
  });
  const cli = browserCommand((_name, run) => run, { catalog: () => ({ actions: [{ name: 'screenshot', image: true }], params: [] }) });
  const bash = defineTool({
    name: 'bash', description: 'Shell', parameters: {},
    output: { schema: { type: 'json' }, render: (_args, v) => [{ type: 'text', text: v.stdout || 'done' }] },
    execute: async () => ({ kind: 'foreground', ...await cli(['screenshot'], { signal }) }),
  });
  tools.register(bash);
  registerDeviceTools(ctx, [browser]);
  const toolSet = await resolve(agent);
  const execute = () => tools.execute({ agent, signal, toolSet, calls: [{ type: 'tool-call', id: 'shell', name: 'bash', arguments: '{}' }] });
  try {
    const shot = (await execute()).results[0].result;
    assert.deepEqual(shot.content.find(block => block.type === 'image')?.attachment, image);
    agent.ctx.on('tools/post-execute', (exec, _result, next) => exec.name === 'bash'
      ? { kind: 'block', feedback: [{ type: 'text', text: 'blocked' }] } : next());
    const blocked = (await execute()).results[0].result;
    assert.equal(blocked.isError, true);
    assert.deepEqual(blocked.content, [{ type: 'text', text: 'blocked' }]);
  } finally { toolSet.dispose(); }
});

test('disposing another engine keeps shared static device definitions available', async t => {
  const first = await setup(t), second = await setup(t);
  const plugin = await first.ctx.plugin({ inject: ['tools'], apply: c => registerDeviceTools(c, [TOOLS.calendar]) });
  registerDeviceTools(second.ctx, [TOOLS.calendar]);
  const agent = second.makeAgent('a');
  assert.match((await second.run(agent, ['--help'])).stdout, /calendar/);
  await plugin.dispose();
  assert.match((await second.run(agent, ['calendar', '--help'])).stdout, /--all-day/);
});
