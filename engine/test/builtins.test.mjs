import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { builtinsRecord, enableBuiltins } from '../plugins/ios-host/builtins.mjs';
import { PINS } from '../plugins/ios-host/pins.mjs';

const pins = { 'ds-bot': { version: '0.3.1', builtin: true }, other: { version: '1.0.0' } };

test('a builtin is switched on once, and a later switch-off is left alone', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-builtins-'));
  const calls = [];
  const manager = { setBundleEnabled: async (name, enabled) => { calls.push([name, enabled]); return { application: 'applied' }; } };
  assert.deepEqual(await enableBuiltins(manager, dir, { pins }), ['ds-bot']);
  assert.deepEqual(await enableBuiltins(manager, dir, { pins }), []);
  assert.deepEqual(calls, [['ds-bot', true]]);
  assert.deepEqual(JSON.parse(fs.readFileSync(builtinsRecord(dir), 'utf8')), { 'ds-bot': '0.3.1' });
});

test('a refusal is reported and tried again on the next start', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-builtins-'));
  const warnings = [];
  let refuse = true;
  const manager = { setBundleEnabled: async () => (refuse ? { error: { code: 'unknown-plugin' } } : { application: 'applied' }) };
  assert.deepEqual(await enableBuiltins(manager, dir, { pins, warn: (message) => warnings.push(message) }), []);
  assert.match(warnings[0], /ds-bot not switched on: unknown-plugin/);
  refuse = false;
  assert.deepEqual(await enableBuiltins(manager, dir, { pins }), ['ds-bot']);
});

test('every builtin ships in the engine at its pinned version', () => {
  const engine = JSON.parse(fs.readFileSync(new URL('../package.json', import.meta.url), 'utf8'));
  for (const [name, pin] of Object.entries(PINS).filter(([, pin]) => pin.builtin)) {
    assert.equal(engine.dependencies[name], pin.version, name);
  }
});
