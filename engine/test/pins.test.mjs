import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { Context } from '@deepseek-ai/cordis';
import IosHost from '../plugins/ios-host/index.mjs';
import { PINS, pinFor, pinRefusal } from '../plugins/ios-host/pins.mjs';

const pins = { 'ds-bot': { version: '0.3.1', repository: 'Fei2411/DS-Bot' } };
const pin = (spec, dir) => pinFor(spec, { pins, dir });
const refused = (spec, wanted) => assert.deepEqual(pin(spec), { name: 'ds-bot', version: '0.3.1', wanted, refused: true }, spec);

test('the shipped pins name a version and a repository', () => {
  assert.match(PINS['ds-bot'].version, /^\d+\.\d+\.\d+$/);
  assert.equal(PINS['ds-bot'].repository, 'Fei2411/DS-Bot');
});

test('a registry spec with no version, a tag or a range installs the pinned version, saved exactly', () => {
  for (const spec of ['ds-bot', 'ds-bot@latest', 'ds-bot@^0.3.0', 'ds-bot@0.3.x', ' ds-bot@0.3.1 ', 'ds-bot@=0.3.1']) {
    assert.deepEqual(pin(spec), { name: 'ds-bot', version: '0.3.1', spec: 'ds-bot@0.3.1', exact: true }, spec);
  }
  assert.deepEqual(pin('bot@npm:ds-bot@latest'), { name: 'ds-bot', version: '0.3.1', spec: 'bot@npm:ds-bot@0.3.1', exact: true });
});

test('any other exact version is refused, whatever form names it', () => {
  refused('ds-bot@0.3.2', '0.3.2');
  refused('ds-bot@0.3.0', '0.3.0');
  refused('ds-bot@0.4.0-beta.1', '0.4.0-beta.1');
  refused('bot@npm:ds-bot@0.3.2', '0.3.2');
  refused('github:Fei2411/DS-Bot#v0.3.2', 'v0.3.2');
  refused('github:fei2411/ds-bot', 'default branch');
  refused('Fei2411/DS-Bot#main', 'main');
  refused('git+https://github.com/Fei2411/DS-Bot.git#v0.3.0', 'v0.3.0');
  refused('git@github.com:Fei2411/DS-Bot.git#v0.3.2&path:/ds-bot', 'v0.3.2');
  refused('https://github.com/Fei2411/DS-Bot#v0.3.2', 'v0.3.2');
  refused('https://registry.npmjs.org/ds-bot/-/ds-bot-0.3.2.tgz', '0.3.2');
  refused('https://github.com/Fei2411/DS-Bot/archive/refs/tags/v0.3.2.tar.gz', '0.3.2');
  refused('https://codeload.github.com/Fei2411/DS-Bot/tar.gz/refs/tags/v0.3.2', '0.3.2');
});

test('the pinned version is allowed in every form, unchanged', () => {
  assert.equal(pin('github:Fei2411/DS-Bot#v0.3.1').spec, 'github:Fei2411/DS-Bot#v0.3.1');
  assert.equal(pin('https://registry.npmmirror.com/ds-bot/-/ds-bot-0.3.1.tgz').refused, undefined);
  assert.equal(pin('https://github.com/Fei2411/DS-Bot/archive/refs/tags/v0.3.1.tar.gz').refused, undefined);
});

test('a local folder or tarball is judged by its manifest or file name', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-pins-'));
  fs.mkdirSync(path.join(dir, 'checkout'));
  fs.writeFileSync(path.join(dir, 'checkout', 'package.json'), JSON.stringify({ name: 'ds-bot', version: '0.3.2' }));
  assert.equal(pin('link:./checkout', dir).refused, true);
  assert.equal(pin(path.join(dir, 'checkout')).refused, true);
  fs.writeFileSync(path.join(dir, 'checkout', 'package.json'), JSON.stringify({ name: 'ds-bot', version: '0.3.1' }));
  assert.equal(pin('file:./checkout', dir).refused, undefined);
  assert.equal(pin('./ds-bot-0.3.2.tgz', dir).refused, true);
  assert.equal(pin('./missing', dir), undefined);
});

test('other packages pass through untouched', () => {
  for (const spec of ['@liustack/modlens', 'ds-bot-extra@1.0.0', 'https://example.com/ds-bot-extra-1.0.0.tgz', 'github:someone/other#v1.0.0', 'dsh-bot@0.2.0', '']) {
    assert.equal(pin(spec), undefined, spec);
  }
});

test('the refusal says which version the app keeps', () => {
  assert.equal(pinRefusal({ name: 'ds-bot', version: '0.3.1', wanted: '0.3.2' }), 'ds-bot is pinned to 0.3.1 in Fish Pocket; 0.3.2 cannot be installed.');
});

test('the plugin manager installs pinned specs at the pinned version and refuses others', async () => {
  const version = PINS['ds-bot'].version;
  const calls = [];
  const manager = {
    change: async () => ({}),
    profile: { dir: os.tmpdir() },
    inspect(spec) { calls.push(['inspect', spec]); return Promise.resolve({ status: 'accepted', kind: 'registry', name: 'ds-bot' }); },
    installBundle(spec, options) { calls.push(['install', spec, options]); return Promise.resolve({ application: 'applied' }); },
  };
  const original = { inspect: manager.inspect, installBundle: manager.installBundle };
  const ctx = new Context();
  ctx.provide('pluginManager');
  ctx.provide('agents');
  ctx.set('pluginManager', manager);
  ctx.set('agents', { list: () => [] });
  const fiber = ctx.plugin(IosHost);
  await new Promise((done) => setTimeout(done, 20));

  await manager.inspect('ds-bot', {});
  await manager.installBundle('ds-bot', { enabled: false });
  await manager.installBundle('@liustack/modlens', { enabled: true });
  assert.deepEqual(calls, [
    ['inspect', `ds-bot@${version}`],
    ['install', `ds-bot@${version}`, { enabled: false, saveExact: true }],
    ['install', '@liustack/modlens', { enabled: true }],
  ]);

  calls.length = 0;
  const inspected = await manager.inspect('ds-bot@99.0.0', {});
  assert.deepEqual(inspected, { status: 'refused', problem: 'unknown', reason: `ds-bot is pinned to ${version} in Fish Pocket; 99.0.0 cannot be installed.` });
  const installed = await manager.installBundle('ds-bot@99.0.0', {});
  assert.equal(installed.application, 'failed');
  assert.equal(installed.changed, false);
  assert.equal(installed.error.code, 'operation-error');
  assert.match(installed.error.diagnostic, /^ds-bot is pinned to /);
  assert.deepEqual(calls, []);

  await fiber.dispose();
  assert.equal(manager.inspect, original.inspect);
  assert.equal(manager.installBundle, original.installBundle);
});
