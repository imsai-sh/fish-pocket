// Start an emulated Node child (see worker-main.mjs) from a node-style argv.
import { Duplex, PassThrough, Writable } from 'node:stream';
import { Worker } from 'node:worker_threads';
import { createRequire } from 'node:module';
import path from 'node:path';
import { PRELOAD } from './real-paths.mjs';

const require = createRequire(import.meta.url);
const MAIN = new URL('./worker-main.mjs', import.meta.url);

/** Package-manager CLIs that are JavaScript and therefore runnable as Node children. */
// pnpm exports only its package.json, which locates the package directory.
const pnpmBin = (name) => path.join(path.dirname(require.resolve('pnpm')), 'bin', name);
export const NODE_CLIS = {
  pnpm: () => pnpmBin('pnpm.mjs'),
  pnpx: () => pnpmBin('pnpx.mjs'),
};

// Node options that take a value; everything else starting with '-' is a flag.
const VALUED = new Set(['-r', '--require', '--import', '--loader', '--experimental-loader', '--conditions', '-C', '--input-type', '--title', '--env-file', '--max-old-space-size']);

/**
 * Parse `node [options] [script | -e code | -p code] [args...]`.
 * `flags` keeps the options before the program: PTC's bootstrap passes
 * `--experimental-vm-modules` there, and its heap cap arrives the same way.
 * @returns {{ script?: string, code?: string, print?: boolean, args: string[], flags: string[], version?: boolean }}
 */
export function parseNodeArgv(args, cwd) {
  const flags = [];
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === '-v' || arg === '--version') return { version: true, args: [], flags };
    if (arg === '-e' || arg === '--eval' || arg === '-p' || arg === '--print') {
      return { code: args[i + 1] ?? '', print: arg === '-p' || arg === '--print', args: args.slice(i + 2), flags };
    }
    if (arg === '--') return { script: path.resolve(cwd, args[i + 1]), args: args.slice(i + 2), flags };
    if (arg.startsWith('-')) {
      flags.push(arg);
      if (VALUED.has(arg)) {
        const value = args[i + 1];
        if (value !== undefined) flags.push(value);
        i++;
      }
      continue;
    }
    return { script: path.resolve(cwd, arg), args: args.slice(i + 1), flags };
  }
  return { args: [], flags };
}

// Worker execArgv accepts per-isolate options only; V8 and process-wide flags
// throw. Add the ones the emulation can honor, never the whole argv.
const WORKER_FLAGS = new Set(['--experimental-vm-modules']);

/** The worker's own heap cap (`resourceLimits`), from the child's `--max-old-space-size`. */
function workerLimits(flags) {
  for (let i = 0; i < flags.length; i++) {
    const inline = /^--max-old-space-size=(\d+)$/.exec(flags[i]);
    if (inline) {
      const mb = Number(inline[1]);
      if (mb > 0) return { maxOldGenerationSizeMb: mb };
    }
    if (flags[i] === '--max-old-space-size' && /^\d+$/.test(flags[i + 1] ?? '')) {
      const mb = Number(flags[i + 1]);
      if (mb > 0) return { maxOldGenerationSizeMb: mb };
    }
  }
  return undefined;
}

/**
 * The parent end of a `stdio.control` pipe. Bytes written here reach the
 * worker's `net.Socket({ fd: 7 })` stand-in over its message port, and bytes
 * written there arrive here. No inherited descriptor is involved (a worker has
 * none); PTC speaks one JSON message per line in both directions.
 */
function controlPipe(worker) {
  const stream = new Duplex({
    read() {},
    write(chunk, _encoding, callback) {
      try { worker.postMessage({ control: Buffer.from(chunk) }); callback(); }
      catch (error) { callback(error); }
    },
    final(callback) { try { worker.postMessage({ controlEnd: true }); } catch {} callback(); },
    destroy(error, callback) { try { worker.postMessage({ controlEnd: true }); } catch {} callback(error); },
  });
  worker.on('message', (message) => {
    if (message?.control !== undefined) stream.push(Buffer.from(message.control));
    else if (message?.controlEnd) stream.push(null);
  });
  worker.on('exit', () => {
    if (stream.destroyed) return;
    stream.push(null);
    stream.destroy();
  });
  return stream;
}

/**
 * Run one emulated Node child.
 * @param {object} spec - { script | code (+print), args, flags, cwd, env, stdin: boolean, ipc: boolean, control: boolean }
 * @returns {{ worker: Worker, stdin?: import('node:stream').Writable, stdout, stderr, control?: import('node:stream').Duplex, exited: Promise<number> }}
 */
export function startNodeWorker({ script, code, print, args = [], flags = [], cwd, env, stdin = false, ipc = false, control = false }) {
  const workerEnv = { ...(env ?? process.env) };
  // The child entry reads this and opens fd 7; it is consumed, not inherited.
  if (control) workerEnv.DSH_SUBPROCESS_CONTROL = 'pipe';
  const limits = workerLimits(flags);
  const worker = new Worker(MAIN, {
    workerData: { script, code, print, cwd, ipc, stdin, control },
    // process.argv is [execPath, <worker entry>, ...argv]; worker-main puts the script at [1].
    argv: args,
    env: workerEnv,
    stdout: true,
    stderr: true,
    execArgv: [...PRELOAD, ...flags.filter((flag) => WORKER_FLAGS.has(flag))],
    ...(limits ? { resourceLimits: limits } : {}),
    // Node's per-worker fd bookkeeping misreads module-loader fds on iOS and
    // floods stderr with "unmanaged mode" warnings; the worker owns no fds we close.
    trackUnmanagedFds: false,
  });
  // Our own stderr, so a failure to start (e.g. a missing script) is reported
  // the way a real child would print it.
  const stderr = new PassThrough();
  worker.stderr.pipe(stderr, { end: false });
  const workerStderrEnded = new Promise((resolve) => worker.stderr.once('end', resolve));
  const exited = new Promise((resolve) => {
    let failed = false;
    worker.on('error', (error) => { failed = true; stderr.write(`${error?.stack ?? error}\n`); });
    worker.on('exit', async (exitCode) => {
      await Promise.race([workerStderrEnded, new Promise((r) => setTimeout(r, 50))]);
      stderr.end();
      resolve(failed && exitCode === 0 ? 1 : exitCode ?? 1);
    });
  });
  // stdin travels over the worker port (see worker-main.mjs): Node's own
  // worker stdin keeps the thread alive even when the script never reads it.
  const input = stdin ? new Writable({
    write(chunk, _encoding, callback) { try { worker.postMessage({ stdin: Buffer.from(chunk) }); } catch {} callback(); },
    final(callback) { try { worker.postMessage({ stdinEnd: true }); } catch {} callback(); },
  }) : undefined;
  const pipe = control ? controlPipe(worker) : undefined;
  return { worker, stdin: input, stdout: worker.stdout, stderr, control: pipe, exited };
}
