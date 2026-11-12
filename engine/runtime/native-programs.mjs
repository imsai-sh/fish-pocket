// The programs linked into the app, as one table: Python (python/index.mjs)
// and FFmpeg (ffmpeg/index.mjs). Each runs its processes on threads of their
// own with pipes for stdio (native-process.mjs). Everything that decides how
// a command runs asks here: child_process's route() (child-process.mjs), the
// shell's command list (shell.mjs) and DSH's subprocess backend
// (plugins/subprocess-ios). A new runtime is one more entry.
import { FFMPEG_COMMANDS, ffmpegAvailable, ffmpegCommands, planFfmpeg, startFfmpeg } from './ffmpeg/index.mjs';
import { PYTHON_COMMANDS, planPython, pythonAvailable, pythonCommands, startPython } from './python/index.mjs';

export { drained } from './native-process.mjs';

const PROGRAMS = [
  { name: 'python', available: pythonAvailable, commands: PYTHON_COMMANDS, plan: planPython, start: startPython, shellCommands: pythonCommands },
  { name: 'ffmpeg', available: ffmpegAvailable, commands: FFMPEG_COMMANDS, plan: planFfmpeg, start: startFfmpeg, shellCommands: ffmpegCommands },
];

/** Command names the linked programs answer to (none on a development machine). */
export function nativeCommandNames() {
  return PROGRAMS.filter((program) => program.available()).flatMap((program) => program.commands);
}

/** The linked programs as just-bash commands. */
export function nativeShellCommands(defineCommand, decode) {
  return PROGRAMS.filter((program) => program.available()).flatMap((program) => program.shellCommands(defineCommand, decode));
}

/**
 * Plan argv (or a simple `sh -c` line) as one process of a linked program.
 * @returns {{ program: string, plan: object } | undefined}
 */
export function planNative(argv, options) {
  for (const program of PROGRAMS) {
    const plan = program.plan(argv, options);
    if (plan) return { program: program.name, plan };
  }
  return undefined;
}

/** Start a planned process in `cwd`: { pid, stdin, stdout, stderr, exited, kill }. */
export function startNative({ program, plan }, cwd) {
  return PROGRAMS.find((entry) => entry.name === program).start({ ...plan, cwd });
}
