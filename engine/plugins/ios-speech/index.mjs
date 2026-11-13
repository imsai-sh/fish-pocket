// DeepSeek speech for the app's own screens: hold-to-talk recognition and
// replies read aloud. These are routes for the app, not tools: the model never
// sees them. The request goes out from here, so the app never holds the key:
// the DeepSeek API key stored for the models first, else the DeepSeek account
// sign-in. DeepSeek refuses the account token on these routes for now (401),
// unlike its search and fetch; it is still sent, so speech works once it is accepted.
//
//   GET  /api/ios-speech/status  → { ready }: a credential to send exists.
//   POST /api/ios-speech/asr     WAV bytes → { text }.
//   POST /api/ios-speech/tts     { text, voice } → 24 kHz 16-bit mono PCM, streamed as it is made.
//   GET  /api/ios-speech/feed    server-sent `say` { text } and `stop`: what the agent's `speak`
//                                tool asks the app to read, in the voice the user picked there.
//
// A failure answers 502 with { error: { kind, status?, message? } }: `kind` is
// `no-credential`, `http` (DeepSeek answered `status`) or `network`.
import { credentialRef } from '@deepseek-ai/dsh-credentials';

export const BASE = 'https://api.deepseek.com/v1/tools';
const KEY_REF = 'DEEPSEEK_API_KEY';
const ROUTE = '/api/ios-speech';
/** Longest recognition wait: two minutes of audio come back in a few seconds. */
const ASR_TIMEOUT_MS = 30_000;
const VOICES = new Set(['stella', 'tide']);

/**
 * The headers that pay for one call to `endpoint`, or undefined when there is no credential: the
 * API key, else the account token. A key that cannot be read counts as none.
 */
export async function credentialHeaders(ctx, endpoint) {
  const credentials = ctx.get('credentials');
  const key = credentials === undefined
    ? process.env[KEY_REF]
    : (await credentials.resolve(credentialRef(KEY_REF)).catch(() => undefined))?.value;
  if (key?.trim()) return { authorization: `Bearer ${key.trim()}` };
  const token = await ctx.get('deepseekAccount')?.resolveToken(endpoint).catch(() => undefined);
  return token ? { 'x-dsh-auth-token': token } : undefined;
}

const json = (value, status = 200) =>
  new Response(JSON.stringify(value), { status, headers: { 'content-type': 'application/json' } });

const failure = (kind, extra = {}) => json({ error: { kind, ...extra } }, 502);

/** DeepSeek's own error text, without the trailing request id. `credential` says what was sent. */
async function upstreamFailure(ctx, path, response, credential) {
  let message;
  try { message = (await response.json())?.error?.message; } catch { /* not JSON */ }
  message = message?.replace(/\s*\(request_id:[^)]*\)\s*$/, '');
  ctx.logger?.warn?.('%s answered %d to the %s: %s', path, response.status, credential, message ?? '');
  return failure('http', { status: response.status, credential, message });
}

async function call(ctx, path, init, signal) {
  const endpoint = `${BASE}${path}`;
  const headers = await credentialHeaders(ctx, endpoint);
  if (headers === undefined) return { response: failure('no-credential') };
  try {
    const response = await fetch(endpoint, { ...init, headers: { ...init.headers, ...headers }, signal, redirect: 'error' });
    if (response.ok) return { upstream: response };
    const credential = headers.authorization === undefined ? 'account' : 'api-key';
    return { response: await upstreamFailure(ctx, path, response, credential) };
  } catch (error) {
    if (signal?.aborted) throw error;
    return { response: failure('network', { message: error?.cause?.message ?? error?.message }) };
  }
}

/** The app's open feeds; the agent's `speak` tool reaches the app through them. */
const feeds = new Set();
const encoder = new TextEncoder();
/** Under the app's two-minute idle timeout. */
const KEEPALIVE_MS = 30_000;

function send(controller, chunk) {
  try { controller.enqueue(encoder.encode(chunk)); } catch { feeds.delete(controller); }
}

/**
 * Ask the app to read `text` aloud (`say`) or to stop (`stop`). False when no app is listening.
 */
export function tellApp(event, data = {}) {
  if (feeds.size === 0) return false;
  for (const controller of feeds) send(controller, `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
  return true;
}

export default class IosSpeech {
  static inject = ['connection'];

  constructor(ctx) {
    ctx.effect(() => ctx.connection.fetch.register({
      path: `${ROUTE}/status`,
      methods: ['GET'],
      requestBody: 'buffered',
      fetch: async () => json({ ready: (await credentialHeaders(ctx, `${BASE}/tts`)) !== undefined }),
    }), 'ios-speech: status');

    ctx.effect(() => ctx.connection.fetch.register({
      path: `${ROUTE}/feed`,
      methods: ['GET'],
      requestBody: 'buffered',
      fetch: async (request) => {
        let own;
        const leave = () => {
          feeds.delete(own);
          try { own.close(); } catch { /* already closed */ }
        };
        const body = new ReadableStream({
          start(controller) {
            own = controller;
            feeds.add(controller);
            send(controller, ': hello\n\n');
          },
          cancel() { leave(); },
        });
        request.signal.addEventListener('abort', leave, { once: true });
        return new Response(body, { status: 200, headers: { 'content-type': 'text/event-stream; charset=utf-8', 'cache-control': 'no-store' } });
      },
    }), 'ios-speech: feed');

    ctx.effect(() => {
      const keepalive = setInterval(() => { for (const controller of feeds) send(controller, ': keepalive\n\n'); }, KEEPALIVE_MS);
      keepalive.unref?.();
      return () => {
        clearInterval(keepalive);
        for (const controller of feeds) { try { controller.close(); } catch { /* closed */ } }
        feeds.clear();
      };
    }, 'ios-speech: feed keepalive');

    ctx.effect(() => ctx.connection.fetch.register({
      path: `${ROUTE}/asr`,
      methods: ['POST'],
      requestBody: 'buffered',
      fetch: async (request) => {
        const form = new FormData();
        form.append('file', new Blob([await request.arrayBuffer()], { type: 'audio/wav' }), 'speech.wav');
        const signal = AbortSignal.any([request.signal, AbortSignal.timeout(ASR_TIMEOUT_MS)]);
        const { upstream, response } = await call(ctx, '/asr', { method: 'POST', body: form }, signal);
        if (response) return response;
        const body = await upstream.json();
        return json({ text: typeof body?.text === 'string' ? body.text : '' });
      },
    }), 'ios-speech: asr');

    ctx.effect(() => ctx.connection.fetch.register({
      path: `${ROUTE}/tts`,
      methods: ['POST'],
      requestBody: 'buffered',
      fetch: async (request) => {
        let body;
        try { body = await request.json(); } catch { body = {}; }
        const text = typeof body?.text === 'string' ? body.text : '';
        const voice = VOICES.has(body?.voice) ? body.voice : 'stella';
        const { upstream, response } = await call(ctx, '/tts', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ text, voice_id: voice, format: 'pcm', filter_markdown: true }),
        }, request.signal);
        return response ?? new Response(upstream.body, { status: 200, headers: { 'content-type': 'audio/pcm' } });
      },
    }), 'ios-speech: tts');
  }
}
