// CLI flags come from the registered schema. Keep the original spelling valid as well.
export const flagName = name => name.replace(/[A-Z]/g, ch => '-' + ch.toLowerCase());

function argumentValue(raw, schema, name) {
  if (schema.type === 'boolean') {
    if (raw === 'true' || raw === 'false') return raw === 'true';
    throw new Error(name + ' needs true or false');
  }
  if (schema.type === 'integer' || schema.type === 'number') {
    const value = Number(raw);
    if (!raw.trim() || !Number.isFinite(value) || (schema.type === 'integer' && !Number.isSafeInteger(value))) {
      throw new Error(name + ' needs ' + schema.type);
    }
    return value;
  }
  if (schema.type === 'array' || schema.type === 'object') {
    let value;
    try { value = JSON.parse(raw); } catch { /* Report the expected CLI shape below. */ }
    if (schema.type === 'array' ? Array.isArray(value) : value !== null && typeof value === 'object' && !Array.isArray(value)) return value;
    throw new Error(name + ' needs a JSON ' + schema.type);
  }
  if (schema.enum && !schema.enum.includes(raw)) throw new Error(name + ' must be one of ' + schema.enum.join(', '));
  return raw;
}

export function optionHelp(properties) {
  return Object.entries(properties).map(([name, schema]) => {
    const type = schema.type === 'array' ? (schema.items?.type ?? 'value') + '[] as JSON' : schema.type;
    return '--' + flagName(name) + ' (' + type + ')  ' + (schema.description ?? '');
  });
}

export function parseOptions(argv, properties, required = []) {
  const names = new Map(Object.keys(properties).flatMap(name => [[name, name], [flagName(name), name]]));
  const args = {};
  let positional = false;
  for (let i = 0; i < argv.length; i++) {
    const token = argv[i];
    if (!positional && token === '--') { positional = true; continue; }
    let name, raw;
    if (!positional && token.startsWith('--')) {
      const equal = token.indexOf('=');
      name = names.get(token.slice(2, equal < 0 ? undefined : equal));
      if (!name) throw new Error('Unexpected argument ' + token);
      if (equal >= 0) raw = token.slice(equal + 1);
      else if (properties[name].type === 'boolean' && !['true', 'false'].includes(argv[i + 1])) raw = 'true';
      else if (argv[i + 1] !== undefined && !argv[i + 1].startsWith('--')) raw = argv[++i];
      else throw new Error('--' + flagName(name) + ' needs a value');
    } else {
      name = required.find(key => !Object.hasOwn(args, key));
      if (!name) throw new Error('Unexpected argument ' + token);
      raw = token;
    }
    if (Object.hasOwn(args, name)) throw new Error('Duplicate argument --' + flagName(name));
    args[name] = argumentValue(raw, properties[name], name);
  }
  for (const name of required) if (!Object.hasOwn(args, name)) throw new Error('needs ' + name);
  return args;
}
