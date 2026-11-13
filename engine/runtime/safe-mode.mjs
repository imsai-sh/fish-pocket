// Safe mode: the way back in when a third-party plugin keeps the engine from
// coming up. The app has no interface until the engine prints its URL, so the
// plugin page that would switch the plugin off is out of reach, and its data —
// the plugin included — outlives a reinstall. The launch screen asks for it
// (NodeEngine.requestSafeMode); main.mjs runs this and replaces the worker.
//
// It does what switching each one off on the plugin page does: the package
// leaves the profile's bundle list and stays installed, so it can be switched
// back on, one at a time, to find the one that hangs.
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { writeFileAtomic } from '@deepseek-ai/dsh-atomic-write';
import { PINS } from '../plugins/ios-host/pins.mjs';

/** DSH's own packages and the ones the app ships (pins.json `builtin`) stay. */
export const isThirdParty = (name, pins = PINS) => !name.startsWith('@deepseek-ai/') && pins[name]?.builtin !== true;

/**
 * Switch off every third-party bundle in the profile.
 * @param {string} profile - the profile directory (`$DSH_HOME/profiles/web`).
 * @returns {Promise<string[]>} the names switched off; nothing is written when none are.
 */
export async function disableThirdParty(profile, pins = PINS) {
  const file = path.join(profile, 'package.json');
  const manifest = JSON.parse(await readFile(file, 'utf8'));
  const bundles = manifest.dsh?.profile?.bundles ?? [];
  const off = bundles.filter((name) => isThirdParty(name, pins));
  if (off.length === 0) return [];
  manifest.dsh.profile.bundles = bundles.filter((name) => !off.includes(name));
  // The plugin manager's own form: two-space JSON, owner-only.
  await writeFileAtomic(file, `${JSON.stringify(manifest, undefined, 2)}\n`, { mode: 0o600 });
  return off;
}
