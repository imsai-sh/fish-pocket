import { randomUUID } from 'node:crypto';
import { withActionCaller } from '../../runtime/action-command.mjs';

// A selection belongs to one tools.resolve() lookup, including concurrent calls from the same agent.
const selected = new WeakMap();
const devices = new WeakMap(); // Static definitions may be registered by more than one engine.

export function registerDeviceTools(ctx, definitions) {
  if (!definitions.length) return;
  const { tools } = ctx;
  for (const definition of definitions) {
    ctx.effect(() => {
      const off = tools.register(definition, { when: step => selected.get(step) === definition });
      devices.set(definition, (devices.get(definition) ?? 0) + 1);
      return () => {
        const remaining = devices.get(definition) - 1;
        if (remaining) devices.set(definition, remaining);
        else devices.delete(definition);
        off();
      };
    }, 'ios-native ' + definition.name + ' tool');
  }

  const screenshots = new WeakMap();
  ctx.on('tools/execute', async (exec, next) => {
    if (exec.name !== 'bash' || !exec.agent) return next();
    const owner = { agent: exec.agent, agents: ctx.get('agents'), tools, signal: exec.signal, images: [] };
    try {
      return await withActionCaller(owner, next);
    } finally {
      if (owner.images.length) screenshots.set(exec, owner.images);
      // A promoted or detached job outlives its model tool call.
      owner.images = undefined;
    }
  });
  ctx.on('tools/post-execute', async (exec, result, next) => {
    const images = screenshots.get(exec);
    if (!images) return next();
    screenshots.delete(exec);
    const decision = await next();
    if (result.isError || result.value?.kind !== 'foreground' || result.value.exitCode !== 0
      || decision.kind !== 'accept' || Object.hasOwn(decision, 'content') || Object.hasOwn(decision, 'value')) return decision;
    return { ...decision, content: [...result.content, ...images] };
  });
}

export function deviceDefinitions(tools, agent) {
  return tools.definitions(agent).filter(definition => devices.has(definition) && definition.name !== 'browser');
}

export async function invokeDeviceTool(tools, agent, name, args, signal) {
  const definition = tools.get(name, agent);
  if (!devices.has(definition)) throw new Error(name + ' is unavailable in this conversation.');
  const modelSelection = agent.model.current();
  if (!modelSelection) throw new Error('Select a model for this conversation first.');
  const step = { agent, modelSelection, signal };
  selected.set(step, definition);
  let toolSet;
  try {
    toolSet = await tools.resolve(step);
    if (toolSet.view(agent).get(name) !== definition) throw new Error(name + ' is unavailable in this conversation.');
    const batch = await tools.execute({ agent, signal, toolSet, calls: [
      { type: 'tool-call', id: randomUUID(), name, arguments: JSON.stringify(args) },
    ] });
    return batch.results[0].result;
  } finally {
    toolSet?.dispose();
    selected.delete(step);
  }
}
