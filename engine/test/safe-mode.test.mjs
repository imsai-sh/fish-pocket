import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { disableThirdParty, isThirdParty } from '../runtime/safe-mode.mjs';

const pins = { 'ds-bot': { version: '0.3.1', builtin: true }, pinned: { version: '1.0.0' } };

function profile(manifest) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-safe-mode-'));
  if (manifest !== undefined) fs.writeFileSync(path.join(dir, 'package.json'), typeof manifest === 'string' ? manifest : JSON.stringify(manifest));
  return dir;
}
const read = (dir) => JSON.parse(fs.readFileSync(path.join(dir, 'package.json'), 'utf8'));

test("DSH's own packages and the app's builtins are not third-party; everything else is", () => {
  assert.equal(isThirdParty('@deepseek-ai/dsh-web-app', pins), false);
  assert.equal(isThirdParty('ds-bot', pins), false);
  assert.equal(isThirdParty('pinned', pins), true);
  assert.equal(isThirdParty('dsh-live-compact', pins), true);
  assert.equal(isThirdParty('@someone/dsh-plugin', pins), true);
});

test('third-party bundles leave the list; the packages and the rest of the manifest stay', async () => {
  const manifest = {
    name: 'dsh-profile-web',
    dependencies: { 'dsh-live-compact': '1.1.5', 'dsh-plugin-save-token': '2.0.0' },
    dsh: { profile: { bundles: ['@deepseek-ai/dsh-base', 'dsh-live-compact', 'ds-bot', 'dsh-plugin-save-token'], other: 1 } },
  };
  const dir = profile(manifest);
  assert.deepEqual(await disableThirdParty(dir, pins), ['dsh-live-compact', 'dsh-plugin-save-token']);
  const after = read(dir);
  assert.deepEqual(after.dsh.profile.bundles, ['@deepseek-ai/dsh-base', 'ds-bot']);
  assert.deepEqual(after.dependencies, manifest.dependencies);
  assert.equal(after.dsh.profile.other, 1);
  assert.equal(fs.statSync(path.join(dir, 'package.json')).mode & 0o777, 0o600);
});

test('a profile with nothing to switch off is not rewritten', async () => {
  const text = '{"dsh":{"profile":{"bundles":["@deepseek-ai/dsh-base","ds-bot"]}}}';
  const dir = profile(text);
  assert.deepEqual(await disableThirdParty(dir, pins), []);
  assert.equal(fs.readFileSync(path.join(dir, 'package.json'), 'utf8'), text);
});

test('a missing or unreadable manifest fails and is left as it was', async () => {
  await assert.rejects(disableThirdParty(profile(), pins), { code: 'ENOENT' });
  const dir = profile('{ not json');
  await assert.rejects(disableThirdParty(dir, pins), SyntaxError);
  assert.equal(fs.readFileSync(path.join(dir, 'package.json'), 'utf8'), '{ not json');
});
