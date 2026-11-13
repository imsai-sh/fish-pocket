// Node entry for the iOS host (also runnable on a desktop Node for testing).
// The host starts Node with this file inside the engine's filesystem view
// (native/root) and passes DSH_IOS_HOME and DSH_IOS_DATA, a directory the two
// share. We lay out DSH_HOME/HOME/TMPDIR and run the DSH engine (boot.mjs) in a
// worker thread, publishing its web URL (it carries the access token) to a 0600
// file the host polls.
//
// The worker is what makes "restart DSH" possible: iOS starts Node once per
// process and an app cannot relaunch itself, yet some plugin changes only
// apply at startup. Replacing the worker gives the engine a new isolate and a
// fresh module cache in the same process, on the same port. The engine asks
// for it (plugins/ios-host) and we also restart it if it dies.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Worker } from 'node:worker_threads';
import { PRELOAD } from './runtime/real-paths.mjs';
import { disableThirdParty } from './runtime/safe-mode.mjs';

const data = process.env.DSH_IOS_DATA;
if (!data) throw new Error('DSH_IOS_DATA is not set');
// Set by the iOS host. Without it (a desktop run) everything stays below `data`.
const home = process.env.DSH_IOS_HOME;
const dirs = home
  ? { DSH_HOME: path.join(home, '.dsh'), HOME: home, TMPDIR: '/tmp', workspace: path.join(home, 'workspace') }
  : { DSH_HOME: path.join(data, 'dsh'), HOME: path.join(data, 'home'), TMPDIR: path.join(data, 'tmp'), workspace: path.join(data, 'workspace') };
for (const dir of Object.values(dirs)) fs.mkdirSync(dir, { recursive: true });

// The engine's environment, not this thread's: that one is the process's, and
// the system frameworks in the process read HOME and TMPDIR, which stay real.
const env = {
  ...process.env,
  DSH_HOME: dirs.DSH_HOME,
  HOME: dirs.HOME,
  TMPDIR: dirs.TMPDIR,
  // The first-use workspace goes under this directory (see ios.patch.yml).
  DSH_IOS_DOCUMENTS: process.env.DSH_IOS_DOCUMENTS ?? path.join(data, 'documents'),
  // Skills that ship with the app, ios-environment among them (dsh-skill-filesystem's bundled root).
  DSH_BUNDLED_SKILL_DIR: path.join(path.dirname(fileURLToPath(import.meta.url)), 'skills'),
  SHELL: process.env.SHELL ?? '/bin/bash',
  // Commands resolve inside the in-process shell, whose binaries live in /bin;
  // the OS PATH (simulator runtime dirs, /usr/bin on device) means nothing there.
  PATH: '/bin:/usr/bin',
  // No terminal to answer prompts: pnpm would otherwise stop and ask before
  // purging a node_modules it wants to rebuild.
  pnpm_config_confirm_modules_purge: process.env.pnpm_config_confirm_modules_purge ?? 'false',
};
// iOS sets this to the real container, and nothing in the engine needs it.
delete env.CFFIXED_USER_HOME;
// Workers cannot chdir; the engine inherits the process working directory.
process.chdir(dirs.workspace);

const urlFile = path.join(data, 'web-url');
const log = fs.createWriteStream(path.join(data, 'engine.log'), { flags: 'a', mode: 0o600 });
const redact = (text) => text.replace(/token=[A-Za-z0-9_-]+/g, 'token=…');
// Each line of the log starts with the time it was written: without it a launch
// that is slow and one that is stuck read the same. Output comes in chunks that
// need not end at a line, so only a chunk's line starts get one.
const pad = (n, width = 2) => String(n).padStart(width, '0');
let lineStart = true;
function stamped(text) {
  const now = new Date();
  const time = `${pad(now.getHours())}:${pad(now.getMinutes())}:${pad(now.getSeconds())}.${pad(now.getMilliseconds(), 3)} `;
  const out = (lineStart ? time : '') + text.replace(/\n(?=[^])/g, `\n${time}`);
  lineStart = text.endsWith('\n');
  return out;
}
let published = false;
// Worker output reaches the process through these streams, so the tee sees both.
for (const name of ['stdout', 'stderr']) {
  const stream = process[name];
  const write = stream.write.bind(stream);
  stream.write = (chunk, ...rest) => {
    const text = typeof chunk === 'string' ? chunk : Buffer.from(chunk).toString('utf8');
    if (text) log.write(stamped(redact(text)));
    const match = !published && /dsh web: (http:\/\/\S+)/.exec(text);
    if (match) {
      published = true;
      fs.writeFileSync(`${urlFile}.tmp`, match[1], { mode: 0o600 });
      fs.renameSync(`${urlFile}.tmp`, urlFile);
    }
    return write(redact(text), ...rest);
  };
}
const jitless = String(process.config.variables.node_v8_options ?? '').includes('--jitless') || process.execArgv.includes('--jitless');
console.log(`[dsh-ios] node ${process.version} ${process.platform}/${process.arch} jitless=${jitless} data=${data} at ${new Date().toISOString()}`);

let engine;
let restarting = false;
let crashes = 0;
/// The start a crashed worker waits for, which a restart replaces.
let retry;

function start() {
  fs.rmSync(urlFile, { force: true });
  published = false;
  const startedAt = Date.now();
  engine = new Worker(new URL('./boot.mjs', import.meta.url), {
    env,
    // Engine boot reads Node's module loader internals (see shims/).
    execArgv: [...PRELOAD, '--expose-internals'],
    trackUnmanagedFds: false,
  });
  engine.on('message', (message) => {
    if (message?.type === 'dsh-ios/restart') void restart(message.reason);
  });
  engine.on('error', (error) => console.error('[dsh-ios] engine error', error));
  engine.on('exit', (code) => {
    if (restarting) return;
    // Unexpected exit: back off while it keeps failing early, then try again.
    crashes = Date.now() - startedAt > 60_000 ? 1 : crashes + 1;
    const delay = Math.min(30_000, 1000 * 2 ** (crashes - 1));
    console.error(`[dsh-ios] engine exited (${code}); restarting in ${delay} ms`);
    retry = setTimeout(start, delay);
  });
}

async function restart(reason) {
  if (restarting) return;
  restarting = true;
  clearTimeout(retry);
  console.log(`[dsh-ios] restarting engine${reason ? ` (${reason})` : ''}`);
  await engine.terminate();
  restarting = false;
  start();
}

// Safe mode (runtime/safe-mode.mjs), asked for by the launch screen. A stuck engine
// answers no HTTP, and nothing else reaches this thread, so the request is a file.
// This thread is not the worker's, so a worker that hangs does not hold it up.
const safeModeRequest = path.join(data, 'safe-mode-request');
const safeModeReport = path.join(data, 'safe-mode.json');
setInterval(async () => {
  if (restarting || !fs.existsSync(safeModeRequest)) return;
  fs.rmSync(safeModeRequest, { force: true });
  try {
    const disabled = await disableThirdParty(path.join(dirs.DSH_HOME, 'profiles', 'web'));
    console.log(`[dsh-ios] safe mode: switched off ${disabled.length ? disabled.join(', ') : 'nothing'}`);
    // What the app tells the user once it is in (NodeEngine.takeSafeModeReport).
    fs.writeFileSync(safeModeReport, JSON.stringify({ disabled }), { mode: 0o600 });
  } catch (error) {
    console.error('[dsh-ios] safe mode failed', error);
  }
  await restart('safe mode');
}, 1000).unref();

start();
