// Model route "fish-pocket": DeepSeek models paid for with Fish Pocket credits.
//
// It sits next to the two official routes (DeepSeek account and DeepSeek API
// key) and reuses the official Messages transport unchanged; only the endpoint
// and the credential differ. The endpoint is the Fish Pocket gateway
// (`<api>/anthropic`), which meters each request against the signed-in
// account's credits. The credential is a per-device runtime key the app stores
// through the credentials service after the user signs in to Fish Pocket; it
// can only spend credits through the gateway, never touch the account.
//
// Without a key the route offers no models, so it stays out of the model
// picker until the user signs in. The gateway answers 401 for a revoked key
// (engine code AUTH) and 402 when the credits run out (engine code QUOTA).
import { LlmError, assertUsableApiKey } from '@deepseek-ai/dsh-llm';
import {
  catalogModelInfo,
  deepSeekConfigFields,
  plainOptions,
  registerDeepSeekProvider,
  resolveAdapterOptions,
} from '@deepseek-ai/dsh-llm-deepseek';
import { credentialRef } from '@deepseek-ai/dsh-credentials';
import z from '@deepseek-ai/schemastery';

export const name = 'llm-fish-pocket';
export const inject = ['llm'];
export const PROVIDER = 'fish-pocket';
export const DEFAULT_KEY_REF = 'FISH_POCKET_RUNTIME_KEY';

export const Config = z.object({
  // `models` keeps the transport's built-in catalog (deepseek-flash,
  // deepseek-v4-pro), which is what the gateway prices; it refuses other ids.
  ...deepSeekConfigFields,
  apiKeyEnv: z.string().role('credential-ref').default(DEFAULT_KEY_REF).volatile(),
});

/**
 * Resolve the route's connection. The gateway URL must be configured here:
 * unlike the official route this one never falls back to $DEEPSEEK_BASE_URL or
 * the public DeepSeek API, which would send the runtime key elsewhere.
 * @returns the connection, or null when no gateway is configured.
 */
export function resolveOptions(config) {
  const { apiKeyEnv, baseURL, ...messages } = plainOptions(config);
  if (typeof baseURL !== 'string' || baseURL === '') return null;
  return {
    ...resolveAdapterOptions({ ...messages, baseURL }, undefined),
    apiKeyEnv: credentialRef(apiKeyEnv ?? DEFAULT_KEY_REF),
  };
}

export function apply(ctx, config) {
  const options = () => resolveOptions(config);
  options();

  const resolveKey = async (connection) => {
    const ref = connection.apiKeyEnv;
    const hit = await ctx.get('credentials')?.resolve(ref);
    if (hit !== undefined) return assertUsableApiKey(hit.value, name, ref);
    throw new LlmError(
      `${name}: not signed in to Fish Pocket (no ${ref} credential)`,
      'MISSING_CREDENTIAL',
    );
  };
  const presentKey = async (connection) => {
    try {
      return await resolveKey(connection);
    } catch (error) {
      if (error instanceof LlmError && error.code === 'MISSING_CREDENTIAL') return undefined;
      throw error;
    }
  };
  const connected = () => {
    const connection = options();
    if (connection === null) throw new LlmError(`${name}: no Fish Pocket gateway is configured`, 'MISSING_CREDENTIAL');
    return {
      ...connection,
      offered: connection.models,
      refusals: new Map(),
      badges: new Map(),
    };
  };

  registerDeepSeekProvider(ctx, PROVIDER, {
    providerName: 'Fish Pocket',
    options: connected,
    connect: async () => connected(),
    resolveAuth: async (connection) => ({ headers: { 'x-api-key': await resolveKey(connection) } }),
    admit: () => {},
    discoverModels: async (provider) => {
      const connection = options();
      if (connection === null || (await presentKey(connection)) === undefined) return [];
      return connection.models.map((model) => catalogModelInfo(provider, model));
    },
  });
}

export default { name, inject, Config, apply };
