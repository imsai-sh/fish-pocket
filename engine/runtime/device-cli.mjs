import path from 'node:path';
import { capabilities } from '../plugins/ios-native/binding.mjs';
import { deviceDefinitions, invokeDeviceTool } from '../plugins/ios-native/cli.mjs';
import { actionCaller, nativeCommand, resultText } from './action-command.mjs';
import { optionHelp, parseOptions } from './cli-arguments.mjs';

export function deviceAvailable() {
  return Object.keys(capabilities() ?? {}).some(name => name !== 'browser');
}

export function parseDeviceCommand(argv, definitions) {
  const help = argv[0] === 'help';
  const [name, ...rest] = help ? argv.slice(1) : argv;
  if (!name || name === '--help') return { help: [
    'device <capability> [action] [flags]',
    definitions.map(def => def.name).sort().join(', '),
    'Run device <capability> --help for actions and parameters.',
  ].join('\n') };
  const definition = definitions.find(def => def.name === name);
  if (!definition) throw new Error(name + ' is unavailable in this conversation. Run device --help.');
  const { action, ...properties } = definition.parameters.properties;
  const required = (definition.parameters.required ?? []).filter(key => key !== 'action');
  const op = action ? rest[0] : undefined;
  if (op && op !== '--help' && !action.enum.includes(op)) throw new Error(name + ' action must be one of ' + action.enum.join(', '));
  if (help || rest[0] === '--help' || (action && (!op || rest[1] === '--help'))) {
    return { help: [definition.description, ...(action ? ['Actions: ' + action.enum.join(', ')] : []), ...optionHelp(properties)].join('\n') };
  }
  const params = parseOptions(action ? rest.slice(1) : rest, properties, required);
  return { name, args: op ? { action: op, ...params } : params };
}

export function deviceCommand(defineCommand) {
  return nativeCommand(defineCommand, 'device', async (argv, shell) => {
    const owner = actionCaller();
    const parsed = parseDeviceCommand(argv, deviceDefinitions(owner.tools, owner.agent));
    if (parsed.help !== undefined) return parsed.help;
    const { name, args } = parsed;
    // These native operations take engine file paths, not the shell's virtual CWD.
    const absolute = file => typeof file === 'string' && file ? path.posix.resolve('/', shell.cwd, file) : file;
    if (typeof args.path === 'string') args.path = absolute(args.path);
    if (args.paths) args.paths = args.paths.map(absolute);
    if (args.attachments) args.attachments = args.attachments.map(absolute);
    const signal = shell.signal ?? owner.signal;
    signal.throwIfAborted();
    return resultText(await invokeDeviceTool(owner.tools, owner.agent, name, args, signal));
  });
}
