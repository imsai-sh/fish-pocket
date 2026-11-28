import { AsyncLocalStorage } from 'node:async_hooks';

// Capture the host's Agent before running the shell. Commands share an interpreter and
// may run concurrently; exported shell variables are never an authorization decision.
const owners = new AsyncLocalStorage();

export function withActionCaller(owner, run) {
  return owners.run(owner, run);
}

export function actionCaller() {
  const owner = owners.getStore();
  if (!owner?.agent || !owner.tools || owner.agents?.get(owner.agent.id) !== owner.agent) {
    throw new Error('This command needs an active Fish Pocket conversation.');
  }
  return owner;
}

/** Only the selected agent's CLI may supply the shell-side destination writer. */
export function browserFileWriter(agent) {
  const owner = owners.getStore();
  return owner?.agent === agent ? owner?.saveBrowserFile : undefined;
}

export function nativeCommand(defineCommand, name, run) {
  return defineCommand(name, async (argv, shell) => {
    try {
      const text = await run(argv, shell);
      return { stdout: text + '\n', stderr: '', exitCode: 0 };
    } catch (error) {
      return { stdout: '', stderr: name + ': ' + (error?.message ?? String(error)) + '\n', exitCode: 1 };
    }
  });
}

export function resultText(result) {
  if (result.isError) throw new Error(result.error.message);
  return result.content.filter(block => block.type === 'text').map(block => block.text).join('\n');
}
