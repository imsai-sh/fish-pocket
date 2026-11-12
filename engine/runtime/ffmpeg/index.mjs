// ffmpeg and ffprobe for the in-process execution world: FFmpeg linked into
// the app (native/ffmpeg), each run a thread with pipes for its standard
// streams. This module decides which commands are theirs and starts them. On a
// development machine there is no binding and they are simply not commands.
import path from 'node:path';
import { simpleWords } from '../direct.mjs';
import { collect, startNativeProcess } from '../native-process.mjs';

/** Names the shell gets as commands. */
export const FFMPEG_COMMANDS = ['ffmpeg', 'ffprobe'];
const NAMES = new Set(FFMPEG_COMMANDS);
const SHELLS = new Set(['sh', 'bash', 'dash', 'zsh']);

let cached;

function binding() {
  if (cached !== undefined) return cached;
  try {
    cached = process._linkedBinding('dsh_ffmpeg');
  } catch {
    cached = null;
  }
  return cached;
}

export function ffmpegAvailable() {
  return binding() !== null;
}

/**
 * Plan argv (or a simple `sh -c` line) as one ffmpeg or ffprobe run, if it is
 * one. Leading VAR=value words are accepted and dropped: FFmpeg reads no
 * environment of its own here.
 * @returns {{ argv: string[] } | undefined}
 */
export function planFfmpeg(argv) {
  if (!ffmpegAvailable()) return undefined;
  let words = argv;
  if (SHELLS.has(path.basename(argv[0] ?? ''))) {
    const c = argv.indexOf('-c');
    if (c < 0 || argv[c + 1] === undefined) return undefined;
    words = simpleWords(argv[c + 1]);
    if (words === undefined) return undefined;
  }
  while (words.length > 0 && /^[A-Za-z_][A-Za-z0-9_]*=/.test(words[0])) words = words.slice(1);
  if (words.length === 0 || !NAMES.has(path.basename(words[0])) || (words[0].includes('/') && !words[0].startsWith('/bin/') && !words[0].startsWith('/usr/bin/'))) return undefined;
  return { argv: [path.basename(words[0]), ...words.slice(1)] };
}

/** Start a planned run: streams and an exit promise (native-process.mjs). */
export function startFfmpeg({ argv, cwd }) {
  const ffmpeg = binding();
  if (!ffmpeg) throw new Error('ffmpeg is not available');
  return startNativeProcess(ffmpeg, { argv: argv.map(String), cwd: path.resolve('/', cwd ?? '/') });
}

/** ffmpeg and ffprobe as just-bash commands (output collected, as a script's commands are). */
export function ffmpegCommands(defineCommand, decode) {
  return FFMPEG_COMMANDS.map((name) => defineCommand(name, async (args, ctx) => {
    const child = startFfmpeg({ argv: [name, ...args], cwd: path.resolve('/', ctx.cwd) });
    return collect(child, ctx, decode);
  }));
}
