// Voice calls from the app's call screen. The app does the listening and the speaking
// (Volcengine streaming recognition and synthesis, on the user's own key); the engine only
// needs to know that a session is on a call, so the model answers the way a call needs.
//
//   POST /api/ios-call/state  { sessionId, active }  → { ok: true }
//
// While a session is on a call, each turn's first step gets one note for the model, recorded
// like the time context: a user message of its own source kind, which the app's timeline never
// shows. The app renews the call every `RENEW_MS` and ends it on hang-up; a call the app stopped
// renewing (a crash, a lost connection) lapses after `LEASE_MS`, so no later turn is told it is
// on a call that is over.
import { createUserMessage } from '@deepseek-ai/dsh-llm';

export const ROUTE = '/api/ios-call';
/** The source kind of the note: the app's timeline shows only `user` messages. */
export const SOURCE = 'voice-call';
/** How long a call stays on without word from the app; the app renews it every 30 s. */
export const LEASE_MS = 90_000;

export const NOTE = 'The user is talking with you on a live voice call. Their words reach you through speech '
  + 'recognition, which can mishear a word or split one sentence into two messages: read them '
  + 'charitably, and ask when you cannot tell what they meant. Everything you write is read aloud '
  + 'as you write it, so answer in short, natural spoken sentences in the language the user speaks, '
  + 'without Markdown, lists, tables, code blocks, links or emoji. When something is better seen than '
  + 'heard (code, a long list, a '
  + 'table), say so in a sentence and keep it out of the answer. Say briefly what you are about to '
  + 'do before a long piece of work, so the user is not left in silence. The user can cut in at any '
  + 'time, which stops your answer where they started talking.';

const FAREWELL = 'Choose how to answer this live phone call. For a continuing conversation, speak normally. '
  + 'For a clear farewell or a request to hang up, the final response is a single bash tool call. Use the '
  + 'foreground command `end-call --say "the words to speak before hanging up"`. Put your actual brief '
  + 'farewell in the caller’s language inside --say. For a task followed by hanging up, first complete it, '
  + 'then put its result and your goodbye in --say. The phone speaks those words and disconnects after '
  + 'playback. A plain text farewell leaves the phone connected.';

const calls = new Map();
let lastRevision = 0;

export function liveCall(sessionId, now = Date.now()) {
  const call = calls.get(sessionId);
  if (call && call.until > now) return call;
  calls.delete(sessionId);
}

/** Used by the voice-message plugin as well as this call's own guidance. */
export function onCall(sessionId, now = Date.now()) { return Boolean(liveCall(sessionId, now)); }

export function setCall(sessionId, active, now = Date.now(), callId) {
  const old = liveCall(sessionId, now);
  if (active) {
    if (old && old.id === callId) old.until = now + LEASE_MS;
    else calls.set(sessionId, { id: callId, until: now + LEASE_MS });
  } else if (old?.id === callId) calls.delete(sessionId);
}

/** Only a committed assistant message can propose a farewell. An attempt or
 * a streamed tool name can still be abandoned before DSH runs the command. */
export function recordSpokenAction(session, event) {
  if (event.type !== 'assistant/message') return;
  const voice = liveCall(session.id)?.voice;
  if (!voice || event.data.turn !== voice.turn) return;
  voice.proposal = undefined;
  let spoken = false;
  for (const block of event.data.message.content) {
    if (block.type === 'text' && block.text.trim()) spoken = true;
    if (block.type === 'tool-call') {
      if (block.name === 'bash') voice.proposal = { step: event.data.step, toolCallId: block.id, spoken };
      break;
    }
  }
}

export function noteMessage(voice) {
  // A short ASR utterance can be attributed in full. Do not duplicate long or multimodal input.
  const block = voice?.content?.length === 1 ? voice.content[0] : undefined;
  const caller = block?.type === 'text' && block.text.length <= 256 ? 'The caller just said ' + JSON.stringify(block.text) + '. ' : '';
  const text = voice ? NOTE + '\n\n<system-reminder>\n' + caller + FAREWELL + '\n</system-reminder>' : NOTE;
  return createUserMessage({
    content: [{ type: 'text', text }],
    source: { kind: SOURCE, form: 'snapshot', sections: [{ name: SOURCE, text }] },
  });
}

const json = (value, status = 200) =>
  new Response(JSON.stringify(value), { status, headers: { 'content-type': 'application/json' } });

export default class IosCall {
  static inject = ['connection', 'agents'];

  constructor(ctx) {
    ctx.on('session/event', recordSpokenAction);
    ctx.effect(() => ctx.connection.fetch.register({
      path: `${ROUTE}/state`,
      methods: ['POST'],
      requestBody: 'buffered',
      fetch: async (request) => {
        let body;
        try { body = await request.json(); } catch { body = undefined; }
        const sessionId = typeof body?.sessionId === 'string' ? body.sessionId.trim() : '';
        if (!sessionId || typeof body?.active !== 'boolean') {
          return json({ error: { kind: 'invalid', message: 'expected { sessionId, active }' } }, 400);
        }
        if (body.callId !== undefined || body.revision !== undefined) {
          if (typeof body.callId !== 'string' || !body.callId || !Number.isSafeInteger(body.revision) || body.revision < 1) {
            return json({ error: { kind: 'invalid', message: 'expected a call id and a positive revision' } }, 400);
          }
          // The iOS call center hosts one call. Late renewals/ends must not replace a later call.
          if (body.revision > lastRevision) {
            lastRevision = body.revision;
            if (body.active && liveCall(sessionId)?.id !== body.callId) calls.clear();
            setCall(sessionId, body.active, Date.now(), body.callId);
          }
        } else if (!liveCall(sessionId)?.id) {
          setCall(sessionId, body.active);
        }
        return json({ ok: true });
      },
    }), 'ios-call: state');

    ctx.effect(() => ctx.connection.fetch.register({
      path: `${ROUTE}/farewell`, methods: ['POST'], requestBody: 'buffered',
      fetch: async request => {
        const body = await request.json().catch(() => null);
        const lease = liveCall(body?.sessionId);
        const voice = lease?.voice;
        const confirmed = Boolean(voice?.receipt && lease.id === body?.callId
          && voice.requestId === body.requestId && voice.turn === body.turn
          && voice.receipt.step === body.step && voice.receipt.toolCallId === body.toolCallId);
        return json({ confirmed });
      },
    }), 'ios-call: farewell receipt');

    // Only a turn's first step, and only one that brings new messages: the note is in the
    // history from then on, and a retry (no messages) already has it.
    ctx.on('agent/pre-step', async ({ agent, turn, step, signal }, next) => {
      const decision = await next();
      if (decision.kind === 'reject' || signal?.aborted || decision.messages.length === 0) return decision;
      const call = liveCall(agent.session.id);
      if (!call) return decision;
      const user = decision.messages.findLast(message => message.source?.kind === 'user');
      if (step !== 1) {
        if (user) call.voice = undefined; // A later steer supersedes the spoken request.
        return decision;
      }
      const requestId = user?.source.rpcId;
      const isVoice = call.id && typeof requestId === 'string' && requestId.startsWith('voice-call:' + call.id + ':');
      call.voice = isVoice ? { turn, requestId } : undefined;
      return { ...decision, messages: [...decision.messages, noteMessage(isVoice ? user : undefined)] };
    }, { prepend: true });

    ctx.effect(() => () => { calls.clear(); lastRevision = 0; }, 'ios-call: calls');
  }
}
