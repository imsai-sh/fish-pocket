// Plugins the app ships inside its engine (pins.json `builtin`, listed in the
// engine's own dependencies). The profile resolves a bundle from the installation
// before its own folder, so naming one in the profile's bundle list is all it takes
// to load it, offline. Each is switched on once, the first time an engine that has
// it starts; a user who switches it off later keeps it off.
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { writeFileAtomic } from '@deepseek-ai/dsh-atomic-write';
import { PINS } from './pins.mjs';

/** The record of builtins already switched on once: `{name: version}`. */
export const builtinsRecord = (dir) => path.join(dir, 'builtins.json');

/**
 * Switch on every builtin not switched on before.
 * @param {{ setBundleEnabled: (name: string, enabled: boolean) => Promise<unknown> }} manager
 * @param {string} dir - where the record lives (DSH_IOS_DATA).
 * @param {{ pins?: object, warn?: (message: string) => void }} [options]
 * @returns {Promise<string[]>} the names switched on now.
 */
export async function enableBuiltins(manager, dir, { pins = PINS, warn = () => {} } = {}) {
  const file = builtinsRecord(dir);
  const record = await readFile(file, 'utf8').then(JSON.parse).catch(() => ({}));
  const enabled = [];
  for (const [name, pin] of Object.entries(pins)) {
    if (pin.builtin !== true || Object.hasOwn(record, name)) continue;
    try {
      const result = await manager.setBundleEnabled(name, true);
      if (result?.error) throw new Error(result.error.diagnostic ?? result.error.code);
      record[name] = pin.version;
      enabled.push(name);
    } catch (error) {
      warn(`builtin ${name} not switched on: ${error?.message ?? error}`);
    }
  }
  if (enabled.length > 0) await writeFileAtomic(file, `${JSON.stringify(record, null, 2)}\n`, { mode: 0o600 });
  return enabled;
}
