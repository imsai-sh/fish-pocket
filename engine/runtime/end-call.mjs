// The holder is supplied only around the model's admitted foreground bash batch.
import { AsyncLocalStorage } from 'node:async_hooks';
import { parse } from 'just-bash';

const actions = new AsyncLocalStorage();
export const withEndCallAction = (action, run) => actions.run(action, run);

function literal(parts) {
  let text = '';
  for (const part of parts) {
    const value = part.type === 'DoubleQuoted' ? literal(part.parts)
      : ['Literal', 'SingleQuoted', 'Escaped'].includes(part.type) ? part.value : undefined;
    if (typeof value !== 'string') return undefined;
    text += value;
  }
  return text;
}

/** Admit one literal shell command. Expansion, redirection, background and compound commands
 * still use bash's normal execution, but cannot acquire call controls. */
export function endCallRequest(script) {
  if (typeof script !== 'string') return;
  const command = script.trim();
  if (command === 'end-call') return {};
  if (!/^end-call\s/.test(command)) return;
  let statements;
  try { ({ statements } = parse(command)); } catch { return; }
  if (statements.length !== 1) return;
  const [{ pipelines, background }] = statements;
  if (background || pipelines.length !== 1) return;
  const [{ commands, negated, timed }] = pipelines;
  if (negated || timed || commands.length !== 1) return;
  const [cmd] = commands;
  if (cmd.type !== 'SimpleCommand' || cmd.assignments.length || cmd.redirections.length
    || literal(cmd.name?.parts ?? []) !== 'end-call' || cmd.args.length !== 2
    || literal(cmd.args[0].parts) !== '--say') return;
  const speech = literal(cmd.args[1].parts)?.trim();
  if (speech) return { speech };
}

export function endCallCommand(defineCommand) {
  return defineCommand('end-call', async (args, shell) => {
    const speech = args.length === 2 && args[0] === '--say' ? args[1].trim() : undefined;
    const result = !shell.signal?.aborted && (!args.length || speech) && actions.getStore()?.(speech);
    if (!result) {
      return { stdout: '', stderr: 'In a live voice turn run end-call --say "your goodbye" alone in the foreground after any work is complete.\n', exitCode: 1 };
    }
    return { stdout: (speech ? JSON.stringify({ farewell: result }) : 'Requested hangup after playback.') + '\n', stderr: '', exitCode: 0 };
  });
}
