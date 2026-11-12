// Plugins the app is built against one tested version of (pins.json). The
// native pages talk to their unversioned HTTP API, so any other version — one
// the user picks, or one the plugin installs to update itself — is refused at
// the plugin manager, the one place every install goes through. A spec with no
// version, a dist-tag or a range installs the pinned version instead.
import { readFileSync } from 'node:fs';
import path from 'node:path';

export const PINS = JSON.parse(readFileSync(new URL('./pins.json', import.meta.url), 'utf8'));

const EXACT = /^[=v]?(\d+\.\d+\.\d+(?:-[\w.-]+)?)(?:\+[\w.-]+)?$/;
const VERSION_IN = /v?(\d+\.\d+\.\d+(?:-[\w.-]+?)?)(?=\.tgz$|\.tar\.gz$|\.zip$|$)/;
const exactOf = (text) => EXACT.exec(String(text ?? '').trim())?.[1];

const readLocalManifest = (dir) => {
  try {
    return JSON.parse(readFileSync(path.join(dir, 'package.json'), 'utf8'));
  } catch {
    return undefined;
  }
};

/** `name@range` (or an `alias@npm:name@range`) split at its version; undefined for other forms. */
function registryParts(spec) {
  const target = spec.includes('@npm:') ? spec.slice(spec.indexOf('@npm:') + 5) : spec;
  if (!/^(@[\w.-]+\/)?[\w.-]+(@.*)?$/.test(target)) return undefined;
  const at = target.indexOf('@', 1);
  return at === -1 ? { name: target, range: '' } : { name: target.slice(0, at), range: target.slice(at + 1) };
}

/** `owner/repo` and the fragment's version ref of a GitHub spec; undefined for other forms. */
function githubParts(spec) {
  const match = /^(?:github:|git\+https:\/\/github\.com\/|git\+ssh:\/\/git@github\.com\/|https:\/\/github\.com\/|git@github\.com:|git:\/\/github\.com\/)?([\w.-]+)\/([\w.-]+?)(?:\.git)?(?:#(.*))?$/i.exec(spec);
  if (match === null) return undefined;
  const parts = (match[3] ?? '').split('&').filter(Boolean);
  return { repository: `${match[1]}/${match[2]}`, ref: parts.find((part) => !part.includes(':')) ?? parts.join('&') };
}

/**
 * What a spec installs when it names a pinned plugin: `undefined` for any other
 * package or a form this cannot read (the plugin manager decides those);
 * `{ name, version, spec, exact }` to install — `spec` rewritten to the pinned
 * version, `exact` when the dependency should be saved exactly; or
 * `{ name, version, wanted, refused: true }`.
 * @param {string} spec - as the plugin manager receives it.
 * @param {{ dir?: string, pins?: object }} [options] - `dir` resolves relative paths.
 */
export function pinFor(spec, { dir = process.cwd(), pins = PINS } = {}) {
  const text = String(spec ?? '').trim();
  if (text === '') return undefined;
  const pinned = (name) => (Object.hasOwn(pins, name) ? pins[name] : undefined);
  const byRepository = (repository) => Object.entries(pins).find(([, pin]) => pin.repository?.toLowerCase() === repository.toLowerCase());
  const judge = (name, wanted, allowed) => {
    const { version } = pinned(name);
    if (exactOf(wanted) === version) return { name, version, spec: allowed ?? text, exact: false };
    return { name, version, wanted: wanted || 'unknown', refused: true };
  };

  // A local folder or tarball: its manifest, else its file name.
  const local = /^(?:link:|file:)(.*)$/i.exec(text)?.[1] ?? (/^(?:[/~]|\.\.?(?:[/\\]|$))/.test(text) ? text : undefined);
  if (local !== undefined) {
    const where = path.resolve(dir, local.replace(/^~(?=\/|$)/, process.env.HOME ?? '~'));
    if (/\.(?:tgz|tar\.gz)$/i.test(where)) return byFileName(path.basename(where));
    const manifest = readLocalManifest(where);
    if (typeof manifest?.name !== 'string' || pinned(manifest.name) === undefined) return undefined;
    return judge(manifest.name, manifest.version);
  }

  // A URL: a GitHub archive of a pinned repository, or a tarball named after a pinned package.
  if (/^https?:\/\//i.test(text) && !/^https:\/\/github\.com\/[\w.-]+\/[\w.-]+?(?:\.git)?(?:#.*)?$/i.test(text)) {
    const url = new URL(text);
    const repo = /^\/([\w.-]+)\/([\w.-]+)\//.exec(url.pathname);
    const entry = /(^|\.)github\.com$/i.test(url.hostname) && repo !== null ? byRepository(`${repo[1]}/${repo[2]}`) : undefined;
    if (entry !== undefined) return judge(entry[0], VERSION_IN.exec(url.pathname.split('/').pop())?.[1]);
    return byFileName(decodeURIComponent(url.pathname.split('/').pop() ?? ''));
  }

  const registry = /^(?:github:|git[+:@]|https:)/i.test(text) ? undefined : registryParts(text);
  if (registry !== undefined) {
    if (pinned(registry.name) === undefined) return undefined;
    const { version } = pinned(registry.name);
    const exact = exactOf(registry.range);
    if (exact !== undefined && exact !== version) return { name: registry.name, version, wanted: exact, refused: true };
    const prefix = text.includes('@npm:') ? `${text.slice(0, text.indexOf('@npm:'))}@npm:` : '';
    return { name: registry.name, version, spec: `${prefix}${registry.name}@${version}`, exact: true };
  }

  const github = githubParts(text);
  if (github !== undefined) {
    const entry = byRepository(github.repository);
    if (entry === undefined) return undefined;
    return judge(entry[0], github.ref || 'default branch');
  }
  return undefined;

  function byFileName(file) {
    for (const name of Object.keys(pins)) {
      const base = name.replace(/^@/, '').replace('/', '-');
      const rest = file.startsWith(`${base}-`) ? file.slice(base.length + 1) : '';
      if (/^v?\d/.test(rest)) return judge(name, VERSION_IN.exec(rest)?.[1]);
    }
    return undefined;
  }
}

/** The plugin manager's words for a refused pin; the app matches its start. */
export const pinRefusal = (pin) => `${pin.name} is pinned to ${pin.version} in Fish Pocket; ${pin.wanted} cannot be installed.`;
