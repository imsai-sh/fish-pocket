// Native-addon entry points that cannot load on iOS, redirected to JavaScript
// stand-ins in shims/ at module resolution, so engine files stay untouched.
//
// Built-in plugins (plugins/ios-host/pins.json `builtin`) ship in the engine's own
// node_modules. The plugin manager finds their bundle there, but the loader imports
// their components from the profile folder, which holds none of them: a lookup
// that fails there is tried again from the engine's folder. A copy the profile
// installed itself still wins, being found first.
import { readFileSync } from 'node:fs';
import { registerHooks } from 'node:module';

export const REDIRECTS = {
  '@deepseek-ai/node-addon-system/flock': new URL('../shims/flock.mjs', import.meta.url).href,
  '@vscode/ripgrep': new URL('../shims/ripgrep.mjs', import.meta.url).href,
  sharp: new URL('../shims/sharp.mjs', import.meta.url).href,
};

const pins = JSON.parse(readFileSync(new URL('../plugins/ios-host/pins.json', import.meta.url), 'utf8'));
export const BUILTIN_PACKAGES = new Set(Object.entries(pins).filter(([, pin]) => pin.builtin === true).map(([name]) => name));
/** Where the engine's own dependencies resolve from. */
export const ENGINE_PARENT = new URL('../package.json', import.meta.url).href;

/** `pkg/sub` → `pkg`, `@scope/pkg/sub` → `@scope/pkg`; relative and URL specifiers → undefined. */
export function packageOf(specifier) {
  if (/^(\.|\/|[a-z][a-z0-9+.-]*:)/i.test(specifier)) return undefined;
  const parts = specifier.split('/');
  return specifier.startsWith('@') ? parts.slice(0, 2).join('/') : parts[0];
}

let installed = false;
export function installModuleRedirects() {
  if (installed) return;
  installed = true;
  registerHooks({
    resolve(specifier, context, nextResolve) {
      const url = REDIRECTS[specifier];
      if (url) return { url, format: 'module', shortCircuit: true };
      try {
        return nextResolve(specifier, context);
      } catch (error) {
        if (error?.code !== 'ERR_MODULE_NOT_FOUND' || !BUILTIN_PACKAGES.has(packageOf(specifier)) || context.parentURL === ENGINE_PARENT) throw error;
        return nextResolve(specifier, { ...context, parentURL: ENGINE_PARENT });
      }
    },
  });
}
