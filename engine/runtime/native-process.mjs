// A process of a program linked into the app (Python, ffmpeg): it runs on a
// thread of its own in native code, which hands the engine the other ends of
// its stdin, stdout and stderr pipes. This turns a binding's spawn into
// streams and an exit promise, the same for every such program.
//
// A binding offers spawn(spec, onExit(code, signal)) -> { pid, stdin, stdout,
// stderr } (descriptors) and kill(pid, signal) -> whether it was running.
import net from 'node:net';

export const SIGNALS = { SIGHUP: 1, SIGINT: 2, SIGQUIT: 3, SIGKILL: 9, SIGTERM: 15 };
const SIGNAL_NAMES = Object.fromEntries(Object.entries(SIGNALS).map(([name, number]) => [number, name]));
/** How long a process may take to stop when asked before the engine stops waiting for it. */
const KILL_GRACE_MS = 3000;

/**
 * Start a process through `binding`. Its stdin/stdout/stderr are streams of
 * the pipes it reads and writes; `exited` settles with { code, signal } once
 * it ends (or, after kill, once it has had KILL_GRACE_MS to).
 */
export function startNativeProcess(binding, spec) {
  let settle;
  const exited = new Promise((resolve) => { settle = resolve; });
  let finished = false;
  const ends = binding.spawn(spec, (code, signal) => {
    if (finished) return;
    finished = true;
    settle({ code, signal: signal == null ? null : (SIGNAL_NAMES[signal] ?? `SIG${signal}`) });
  });
  const stdin = new net.Socket({ fd: ends.stdin, readable: false, writable: true });
  const stdout = new net.Socket({ fd: ends.stdout, readable: true, writable: false });
  const stderr = new net.Socket({ fd: ends.stderr, readable: true, writable: false });
  // A process that stops reading leaves writes failing with EPIPE: nothing to report.
  stdin.on('error', () => {});
  for (const stream of [stdout, stderr]) stream.on('error', () => {});
  return {
    pid: ends.pid,
    stdin,
    stdout,
    stderr,
    exited,
    kill(signal = 'SIGTERM') {
      if (finished) return false;
      const number = typeof signal === 'number' ? signal : (SIGNALS[signal] ?? SIGNALS.SIGTERM);
      binding.kill(ends.pid, number);
      if (number === SIGNALS.SIGINT) return true;
      // A program blocked reading its input wakes up on end of input.
      stdin.destroy();
      // One blocked elsewhere (sleep, a socket) is left to finish on its own.
      setTimeout(() => {
        if (finished) return;
        finished = true;
        stdout.destroy();
        stderr.destroy();
        settle({ code: null, signal: SIGNAL_NAMES[number] ?? `SIG${number}` });
      }, KILL_GRACE_MS).unref();
      return true;
    },
  };
}

/** Wait for both output streams to end (or a moment after exit, as runDirect does). */
export function drained(child) {
  const ends = [child.stdout, child.stderr].map((stream) => new Promise((resolve) => {
    if (stream.readableEnded || stream.destroyed) return resolve();
    stream.once('end', resolve);
    stream.once('close', resolve);
  }));
  return Promise.all(ends);
}

/**
 * Run a started process as a just-bash command. Inside a shell script the
 * interpreter takes a command's output when it exits, so this collects it; a
 * top-level command goes through the runtime's plan instead and streams.
 */
export async function collect(child, ctx, decode) {
  let stdout = '';
  let stderr = '';
  child.stdout.setEncoding('utf8').on('data', (chunk) => { stdout += chunk; });
  child.stderr.setEncoding('utf8').on('data', (chunk) => { stderr += chunk; });
  child.stdin.end(decode(ctx.stdin ?? ''));
  const stop = () => child.kill('SIGTERM');
  ctx.signal?.addEventListener('abort', stop, { once: true });
  const { code, signal } = await child.exited;
  await Promise.race([drained(child), new Promise((resolve) => setTimeout(resolve, 100))]);
  ctx.signal?.removeEventListener('abort', stop);
  return { stdout, stderr, exitCode: signal ? 128 + (SIGNALS[signal] ?? 15) : code };
}
