import test from 'node:test';
import assert from 'node:assert/strict';
import { browserCommand, parseBrowserCommand } from '../runtime/browser-cli.mjs';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { MountableFs, ReadWriteFs, OverlayFs } from 'just-bash';
import { browserFileWriter, withActionCaller } from '../runtime/action-command.mjs';

const catalog = {
  actions: [
    { name: 'read', does: 'Read the page', takes: ['tab'] },
    { name: 'click', does: 'Click an element', takes: ['index', 'tab'], needs: ['index'] },
    { name: 'type', does: 'Fill a field', takes: ['index', 'text', 'tab'], needs: ['index', 'text'] },
    { name: 'screenshot', does: 'Take a picture', takes: ['tab', 'fullPage'], image: true },
  ],
  params: ['index', 'tab', 'text', 'fullPage'].map(name => ({ name, schema: {
    type: name === 'index' ? 'integer' : name === 'fullPage' ? 'boolean' : 'string',
  } })),
};
const command = browserCommand((_name, run) => run, { catalog: () => catalog,
  invoke: (tools, agent, _name, args, signal) => tools.runBrowser(agent, args, signal) });
const signal = new AbortController().signal;

test('browser CLI uses the installed catalog and accepts positional and named arguments', () => {
  assert.deepEqual(parseBrowserCommand(['type', '4', '--text', 'two words', '--tab', 't2'], catalog).args,
    { action: 'type', index: 4, text: 'two words', tab: 't2' });
  assert.equal(parseBrowserCommand(['screenshot', '--fullPage', 'false', '--out', 'shot.jpg'], catalog).args.fullPage, false);
  assert.match(parseBrowserCommand(['help', 'read'], catalog).help, /Read the page/);
  assert.throws(() => parseBrowserCommand(['click', 'n'], catalog), /needs integer/);
  assert.throws(() => parseBrowserCommand(['type', '1'], catalog), /needs text/);
  assert.throws(() => parseBrowserCommand(['read', '--session', 'someone'], catalog), /Unexpected argument/);
});

test('CLI retains the host-selected caller across concurrent commands and honors loss of the owning Agent', async () => {
  const owner = id => {
    const agent = { id }, agents = new Map([[id, agent]]);
    return { agent, agents, signal, tools: { async runBrowser(caller, args) {
      assert.equal(caller, agent);
      await new Promise(resolve => setImmediate(resolve));
      return { content: [{ type: 'text', text: caller.id + ' ' + args.action }] };
    } } };
  };
  const a = owner('a'), b = owner('b');
  const shell = { signal, env: new Map([['DSH_SESSION_ID', 'unrelated']]) };
  const run = who => withActionCaller(who, () => command(['read'], shell));
  const results = await Promise.all([run(a), run(b)]);
  assert.deepEqual(results.map(r => r.stdout), ['a read\n', 'b read\n']);
  a.agents.delete('a');
  assert.equal((await run(a)).exitCode, 1);
  assert.equal((await command(['read'], shell)).exitCode, 1);
});

test('screenshots use the approved image result and write through the Shell filesystem', async () => {
  const ref = { attachmentId: 'shot' };
  const attachments = { imageHostPath: () => undefined,
    readImage: async reference => { assert.equal(reference, ref); return { data: Buffer.from('pixels') }; } };
  const agent = { id: 'a', ctx: { get: () => attachments } };
  const tools = { runBrowser: async () => ({ content: [{ type: 'image', attachment: ref }] }) };
  const owner = { agent, tools, signal, agents: new Map([['a', agent]]) };
  let saved;
  const shell = { cwd: '/work', signal, fs: { writeFile: async (p, data) => { saved = [p, data.toString()]; } } };
  const run = () => withActionCaller(owner, () => command(['screenshot', '--out', 'snapshot.jpg'], shell));
  assert.match((await run()).stdout, /\/work\/snapshot.jpg/);
  assert.deepEqual(saved, ['/work/snapshot.jpg', 'pixels']);
  shell.fs.writeFile = async () => { throw new Error('read-only filesystem'); };
  assert.match((await run()).stderr, /read-only/);
  tools.runBrowser = async () => ({ isError: true, error: { message: 'user refused' } });
  assert.match((await run()).stderr, /user refused/);
});

test('advanced actions use the complete browser catalog, including typed lists and dictionaries', () => {
  const advanced = { actions: [
    { name: 'upload', takes: ['index', 'paths'], needs: ['index', 'paths'] },
    { name: 'request', takes: ['url', 'headers'], needs: ['url'] },
    { name: 'setCookie', takes: ['path', 'value'], needs: ['value'] },
  ], params: Object.entries({ index: { type: 'integer' }, paths: { type: 'array', items: { type: 'string' } },
    url: { type: 'string' }, headers: { type: 'object' }, path: { type: 'string' }, value: { type: 'string' } })
      .map(([name, schema]) => ({ name, schema })) };
  const parse = (...argv) => parseBrowserCommand(argv, advanced);
  assert.deepEqual(parse('upload', '1', '["one","two"]').args.paths, ['one', 'two']);
  assert.deepEqual(parse('request', 'https://example.org', '--headers', '{"Accept":"text/plain"}').args.headers, { Accept: 'text/plain' });
  assert.throws(() => parse('request', 'https://example.org', '--headers', '{"Accept":3}'), /string values/);
  assert.match(parse('--help').help, /setCookie/);
  assert.equal(parse('setCookie', 'plain', '--path', '/docs').args.path, '/docs');
});

test('file responses publish through shell mounts and reserve distinct default names', async t => {
  const base = await fs.mkdtemp(path.join(os.tmpdir(), 'cli-output-test-'));
  t.after(() => fs.rm(base, { recursive: true, force: true }));
  const root = path.join(base, 'work');
  await fs.mkdir(root);
  const disk = new MountableFs({
    base: new OverlayFs({ root: '/', mountPoint: '/', readOnly: true, allowSymlinks: true }),
    mounts: [{ mountPoint: root, filesystem: new ReadWriteFs({ root, allowSymlinks: true }) }],
  });
  const pdf = { actions: [{ name: 'pdf', takes: ['path'] }], params: [{ name: 'path', schema: { type: 'string' } }] };
  const agent = { id: 'reader' }, owner = { agent, agents: new Map([[agent.id, agent]]), tools: {}, signal };
  const staged = [];
  const bytes = Buffer.from([0, 255, 16, 128]);
  const run = browserCommand((_name, fn) => fn, { catalog: () => pdf,
    invoke: async (_tools, caller, _name, { action, ...args }) => {
      assert.equal(action, 'pdf');
      const value = await browserFileWriter(caller)(args, async ({ shellOutputFile }) => {
        staged.push(shellOutputFile);
        await fs.writeFile(shellOutputFile, bytes);
        return { savedTo: args.path ?? path.join(root, 'downloads', 'title.pdf') };
      });
      return { content: [{ type: 'text', text: value.savedTo }] };
    } });
  const invoke = (...args) => withActionCaller(owner, () => run(['pdf', ...args], { signal, cwd: root, fs: disk }));
  const generated = await Promise.all([invoke(), invoke()]);
  const outputs = generated.map(result => result.stdout.trim());
  assert.deepEqual(outputs.sort(), [path.join(root,'downloads/title (2).pdf'), path.join(root,'downloads/title.pdf')]);
  for (const file of outputs) assert.deepEqual(await fs.readFile(file), bytes);
  assert.equal((await invoke('--path', 'user.pdf')).exitCode, 0);
  assert.deepEqual(await fs.readFile(path.join(root,'user.pdf')), bytes);
  await fs.writeFile(path.join(base, 'secret.pdf'), 'unchanged');
  await fs.symlink(path.join(base, 'secret.pdf'), path.join(root, 'outside-link'));
  await fs.symlink(path.join(root, 'user.pdf'), path.join(root, 'inside-link'));
  assert.equal((await invoke('--path', 'inside-link')).exitCode, 0);
  assert.equal((await fs.lstat(path.join(root, 'inside-link'))).isSymbolicLink(), true);
  const calls = staged.length;
  assert.equal((await invoke('--path', 'outside-link')).exitCode, 1);
  assert.equal(await fs.readFile(path.join(base, 'secret.pdf'), 'utf8'), 'unchanged');
  assert.equal((await invoke('--path', '../outside.pdf')).exitCode, 1);
  assert.equal(staged.length, calls);
  await fs.symlink(base, path.join(root, 'sibling'));
  assert.equal((await invoke('--path', 'sibling/outside.pdf')).exitCode, 1);
  assert.equal(staged.length, calls);
  await assert.rejects(fs.stat(path.join(base, 'outside.pdf')), { code: 'ENOENT' });
  for (const tmp of staged) await assert.rejects(fs.stat(path.dirname(tmp)), { code: 'ENOENT' });
});
