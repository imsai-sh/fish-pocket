// The on-disk `node` (runtime/node-entry.mjs): programs that search PATH for
// node before spawning it find /usr/bin/node, and spawning it runs Node.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { placeNodeEntry } from '../runtime/node-entry.mjs';
import { planDirect } from '../runtime/direct.mjs';
import { installChildProcess } from '../runtime/child-process.mjs';

installChildProcess();
const cp = await import('node:child_process');

test('the placeholder is written executable, and rewritten when changed', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-ios-node-entry-'));
  const file = placeNodeEntry(root);
  assert.equal(file, path.join(root, 'usr/bin/node'));
  assert.ok(fs.statSync(file).mode & 0o100);
  const content = fs.readFileSync(file, 'utf8');
  fs.writeFileSync(file, 'broken');
  fs.chmodSync(file, 0o644);
  placeNodeEntry(root);
  assert.equal(fs.readFileSync(file, 'utf8'), content);
  assert.ok(fs.statSync(file).mode & 0o100);
});

test('spawning the placeholder runs a Node program', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-ios-node-entry-'));
  const node = placeNodeEntry(root);
  assert.ok(planDirect([node, '-e', '1'], { cwd: root, env: {} }));
  const out = await new Promise((resolve, reject) => {
    cp.execFile(node, ['-e', 'console.log(6 * 7)'], { cwd: root }, (error, stdout) => (error ? reject(error) : resolve(stdout)));
  });
  assert.equal(out.trim(), '42');
});

test('node options reach the worker, not just the argv parser', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-ios-node-entry-'));
  const out = await new Promise((resolve, reject) => {
    cp.execFile(process.execPath, ['--experimental-vm-modules', '-e', 'console.log(typeof require("node:vm").SourceTextModule)'], { cwd: root }, (error, stdout) => (error ? reject(error) : resolve(stdout)));
  });
  assert.equal(out.trim(), 'function');
});

test('a heap cap becomes the worker resource limit', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-ios-node-entry-'));
  const out = await new Promise((resolve, reject) => {
    cp.execFile(process.execPath, ['--max-old-space-size=64', '-e', 'console.log(require("node:v8").getHeapStatistics().heap_size_limit)'], { cwd: root }, (error, stdout) => (error ? reject(error) : resolve(stdout)));
  });
  const limit = Number(out.trim());
  assert.ok(Number.isSafeInteger(limit) && limit > 0 && limit < 256 * 1024 * 1024, out);
});
