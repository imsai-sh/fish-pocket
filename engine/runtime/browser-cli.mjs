import { mkdtemp, rm } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import path from 'node:path';
import { describe } from '../plugins/ios-native/binding.mjs';
import { invokeDeviceTool } from '../plugins/ios-native/cli.mjs';
import { actionCaller, nativeCommand, resultText, withActionCaller } from './action-command.mjs';
import { optionHelp, parseOptions } from './cli-arguments.mjs';

export function browserAvailable() {
  return describe('browser') !== null;
}

export function parseBrowserCommand(argv, catalog) {
  const [op, ...rest] = argv;
  if (!op || op === '--help' || (op === 'help' && !rest.length)) {
    return { help: 'browser <action> [arguments]\n' + catalog.actions.map(item => item.name).join(', ')
      + '\nUse browser help <action> for parameters.' };
  }
  const name = op === 'help' ? rest[0] : op;
  const action = catalog.actions.find(item => item.name === name);
  if (!action) throw new Error('Unknown browser command. Run browser --help.');
  const takes = action.takes ?? [], needs = action.needs ?? [];
  const properties = Object.fromEntries(catalog.params.filter(p => takes.includes(p.name)).map(p => [p.name, p.schema]));
  if (action.image) properties.out = { type: 'string', description: 'Save the screenshot to a file.' };
  if (op === 'help' || rest[0] === '--help') {
    return { help: [action.does, 'browser ' + [name, ...needs.map(key => '<' + key + '>')].join(' '), ...optionHelp(properties)].join('\n') };
  }
  const { out, ...params } = parseOptions(rest, properties, needs);
  if (out === '') throw new Error('--out needs a file path');
  if (params.headers && Object.values(params.headers).some(value => typeof value !== 'string')) {
    throw new Error('headers needs a JSON object of string values');
  }
  return { args: { action: name, ...params }, out };
}

// Reserve the default filename through the same mount that will receive the bytes.
// Two tabs can finish a download with the same suggested name at the same time.
async function reserveDownload(fs, target) {
  const { dir, name, ext } = path.posix.parse(target);
  for (let n = 1; ; n++) {
    const candidate = n === 1 ? target : path.posix.join(dir, name + ' (' + n + ')' + ext);
    try {
      await fs.createExclusive(candidate, { mode: 0o600 });
      return candidate;
    } catch (error) {
      if (error.code !== 'EEXIST' && !error.message.startsWith('EEXIST:')) throw error;
    }
  }
}

async function outputPath(fs, file) {
  let entry;
  try { entry = await fs.lstat(file); }
  catch (error) {
    if (error.code === 'ENOENT' || error.message.startsWith('ENOENT:')) return file;
    throw error;
  }
  return entry.isSymbolicLink ? fs.realpath(file) : file;
}

// Reserve a sibling through the actual shell mount before issuing a request with an explicit
// destination. Publish by rename so a failed download leaves the previous file intact.
async function outputSibling(fs, destination) {
  const directory = path.posix.dirname(destination);
  await fs.mkdir(directory, { recursive: true });
  if (await fs.exists(destination) && (await fs.stat(destination)).isDirectory) {
    throw new Error(destination + ' is a directory; give a file path.');
  }
  const temp = path.posix.join(directory, '.fish-pocket-' + randomUUID());
  await fs.createExclusive(temp, { mode: 0o600 });
  return temp;
}

async function saveBrowserFile(shell, args, perform) {
  const { fs } = shell;
  const directory = await mkdtemp('/tmp/fish-pocket-browser-');
  const staged = path.posix.join(directory, 'output');
  let sibling, reserved, destination;
  try {
    if (args.path) {
      destination = await outputPath(fs, args.path);
      sibling = await outputSibling(fs, destination);
    }
    const value = await perform({ ...args, shellOutputFile: staged });
    if (!value.savedTo) return value;
    shell.signal?.throwIfAborted();
    sibling ??= await outputSibling(fs, value.savedTo);
    await fs.cp(staged, sibling);
    if (!args.path) reserved = await reserveDownload(fs, value.savedTo);
    const target = destination ?? reserved;
    await fs.mv(sibling, target);
    sibling = reserved = undefined;
    return { ...value, savedTo: args.path ?? target };
  } finally {
    try {
      if (sibling) await fs.rm(sibling, { force: true });
      if (reserved) await fs.rm(reserved, { force: true });
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  }
}

export function browserCommand(defineCommand, { catalog = () => describe('browser'), invoke = invokeDeviceTool } = {}) {
  return nativeCommand(defineCommand, 'browser', async (argv, shell) => {
    const parsed = parseBrowserCommand(argv, catalog());
    if (parsed.help !== undefined) return parsed.help;
    const { args, out } = parsed;
    const owner = actionCaller();
    const signal = shell.signal ?? owner.signal;
    signal.throwIfAborted();
    const absolute = file => path.posix.resolve('/', shell.cwd, file);
    const writesFile = args.action === 'pdf' || args.action === 'request';
    if (writesFile && args.path) args.path = absolute(args.path);
    if (args.action === 'upload' && Array.isArray(args.paths)) args.paths = args.paths.map(absolute);
    const call = () => invoke(owner.tools, owner.agent, 'browser', args, signal);
    const result = writesFile ? await withActionCaller({
      ...owner, saveBrowserFile: (params, perform) => saveBrowserFile(shell, params, perform),
    }, call) : await call();
    const lines = [resultText(result)];
    for (const block of result.content.filter(block => block.type === 'image')) {
      const attachments = owner.agent.ctx.get('attachments');
      let file = attachments.imageHostPath(block.attachment);
      if (out !== undefined) {
        const stored = await attachments.readImage(block.attachment, signal);
        signal.throwIfAborted();
        file = absolute(out);
        await shell.fs.writeFile(file, stored.data);
      } else if (owner.images) {
        owner.images.push(block);
      } else if (!file) {
        throw new Error('Use browser screenshot --out <file> to save the picture.');
      }
      if (file) lines.push('Image file: ' + file);
    }
    return lines.filter(Boolean).join('\n');
  });
}
