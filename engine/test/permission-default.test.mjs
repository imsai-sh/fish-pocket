// ios.patch.yml moves the default permission preset to full access. A patch
// replaces the entry's whole config, so it has to repeat the stock preset
// table; this compares the composed profile with the shipped one.
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseDocument } from 'yaml';

const engine = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const bin = path.join(engine, 'node_modules/@deepseek-ai/dsh/lib/bin.js');

/** The `permission` entry's config in the web profile, with or without our overlay. */
const permission = (...flags) => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-permission-'));
  try {
    const dump = execFileSync(process.execPath, [bin, 'web', ...flags], {
      encoding: 'utf8',
      env: { ...process.env, DSH_HOME: home, DSH_IOS_DOCUMENTS: home },
    });
    // The dump keeps `!!js` expressions as tagged scalars; none sit in this entry.
    const entries = parseDocument(dump, { logLevel: 'silent' }).toJS();
    return entries.find((entry) => entry.id === 'permission').config;
  } finally {
    fs.rmSync(home, { recursive: true, force: true });
  }
};

test('new sessions default to full access; the preset table is the shipped one', () => {
  const shipped = permission('--dump-default-config');
  const composed = permission('--patch', path.join(engine, 'ios.patch.yml'), '--dump-config');
  assert.equal(composed.defaultPreset, 'danger-full-access');
  assert.deepEqual(composed.presets, shipped.presets);
  assert.deepEqual(Object.keys(composed.presets), Object.keys(shipped.presets));
});
