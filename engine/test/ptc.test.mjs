// PTC's `run_code` starts a Node child over a `stdio.control` pipe (#171).
// iOS has no fork/exec: the child is a worker thread, and fd 7 is a duplex over
// its message port. These tests exercise that path end to end, including the
// real PTC bootstrap the preset ships.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';
import { Context } from '@deepseek-ai/cordis';
import IosSubprocessRuntime from '../plugins/subprocess-ios/index.mjs';

const require = createRequire(import.meta.url);

async function runtime() {
  const ctx = new Context();
  ctx.plugin(IosSubprocessRuntime);
  await ctx.inject(['subprocess'], () => {});
  await new Promise((r) => setTimeout(r, 10));
  return ctx.get('subprocess');
}

const waitFor = async (read, pattern, ms = 15000) => {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (pattern.test(read())) return true;
    await new Promise((r) => setTimeout(r, 50));
  }
  return false;
};

/** A spawn that asks for PTC's control pipe; stdout/stderr are collected. */
const spec = (argv, cwd) => ({
  argv,
  cwd,
  graceMs: 100,
  stdio: {
    stdin: 'ignore',
    stdout: { maxBytes: 1 << 20 },
    stderr: { maxBytes: 1 << 20 },
    control: 'pipe',
  },
  env: { PATH: '/bin', HOME: cwd },
});

test('a control pipe is a duplex over the worker port', async () => {
  const sp = await runtime();
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-ptc-control-')));
  const script = path.join(dir, 'control.mjs');
  fs.writeFileSync(script, `
import net from 'node:net';
const channel = new net.Socket({ fd: 7, readable: true, writable: true, allowHalfOpen: true });
console.log('marker', process.env.DSH_SUBPROCESS_CONTROL);
channel.on('data', (chunk) => channel.write('echo:' + chunk));
channel.write('hello\\n');
`);
  const h = sp.spawn(spec([process.execPath, script], dir));
  try {
    assert.ok(h.control, 'control stream');

    let received = '';
    h.control.on('data', (chunk) => { received += chunk; });
    assert.ok(await waitFor(() => received, /^hello\n/), received);
    h.control.write('pong\n');
    assert.ok(await waitFor(() => received, /echo:pong\n/), received);
    assert.match(h.collected.stdout.readFrom(0).text, /marker pipe/);
  } finally {
    h.terminate();
    await h.done;
  }
});

test('the real PTC bootstrap starts and runs a program', async () => {
  const sp = await runtime();
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-ptc-run-')));
  const bootstrap = require.resolve('@deepseek-ai/dsh-ptc-runtime-node/process');
  // What PTC's start() does: resolve launch.executable, which is process.execPath.
  const executable = await sp.resolveExecutable(process.execPath);
  const h = sp.spawn(spec([executable, '--max-old-space-size=512', '--experimental-vm-modules', bootstrap, '65536'], dir));
  try {
    assert.ok(h.control, 'control stream');

    const messages = [];
    let buffer = '';
    h.control.on('data', (chunk) => {
      buffer += chunk;
      for (let end = buffer.indexOf('\n'); end >= 0; end = buffer.indexOf('\n')) {
        messages.push(JSON.parse(buffer.slice(0, end)));
        buffer = buffer.slice(end + 1);
      }
    });

    // The bootstrap announces protocol 2 as an event (`t: "q"`, no id); a run
    // is a request, and its answer comes back as `t: "s"` with the same id.
    assert.ok(await waitFor(() => (messages.length ? 'yes' : ''), /yes/), h.collected.stderr.readFrom(0).text);
    const ready = messages.shift();
    assert.equal(ready.m, 'ready');
    assert.deepEqual(ready.a, [2]);

    h.control.write(JSON.stringify({
      t: 'q',
      m: 'run',
      i: '1',
      a: [dir, {
        code: 'return 6 * 7',
        maxOutputBytes: 1 << 20,
        namespaces: [],
        programFormat: 'function-body',
      }],
    }) + '\n');

    assert.ok(await waitFor(() => (messages.some((message) => message.i === '1') ? 'yes' : ''), /yes/), h.collected.stderr.readFrom(0).text);
    const result = messages.find((message) => message.i === '1');
    assert.equal(result.e, undefined);
    assert.deepEqual(result.r?.value, [42]);
  } finally {
    h.terminate();
    await h.done;
  }
});
