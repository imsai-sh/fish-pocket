// Voice calls from the app's call screen. The app does the listening and the speaking
// (Volcengine streaming recognition and synthesis, on the user's own key); the engine only
// needs to know that a session is on a call, so the model answers the way a call needs.
//
//   POST /api/ios-call/state  { sessionId, callId, active }          → { ok: true, leaseId? }
//   POST /api/ios-call/said   { sessionId, leaseId, requestId, text } → { ok: true }
//
// While a session is on a call, each turn's first step gets one note for the model, recorded
// like the time context: a user message of its own source kind, which the app's timeline never
// shows. The app renews the call every `RENEW_MS` and ends it on hang-up; a call the app stopped
// renewing (a crash, a lost connection) lapses after `LEASE_MS`, so no later turn is told it is
// on a call that is over. The idle reminder is bound to the lease and to the request id
// reserved for the user's spoken reply. The app waits for the report before sending that reply.
import { randomUUID } from 'node:crypto';
import { createUserMessage } from '@deepseek-ai/dsh-llm';

export const ROUTE = '/api/ios-call';
/** The source kind of the note: the app's timeline shows only `user` messages. */
export const SOURCE = 'voice-call';
const SAID_SOURCE = 'voice-call-said';
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

/** Session id → the active call's lease and reminder reports. */
const calls = new Map();

function currentCall(sessionId, now = Date.now()) {
  const call = calls.get(sessionId);
  if (call && call.until > now) return call;
  calls.delete(sessionId);
}

/** Whether `sessionId` is on a call at `now`. A lapsed call is forgotten. */
export function onCall(sessionId, now = Date.now()) {
  return currentCall(sessionId, now) !== undefined;
}

/** Start or renew (`active`) or end a session's call. */
export function setCall(sessionId, callId, active, now = Date.now()) {
  const current = currentCall(sessionId, now);
  if (!active) {
    if (current?.callId === callId) calls.delete(sessionId);
    return;
  }
  // A redial or a renewal after expiry starts a fresh lease, with no remembered speech.
  const call = current?.callId === callId ? current : { callId, leaseId: randomUUID(), reminders: new Map() };
  call.until = now + LEASE_MS;
  calls.set(sessionId, call);
  return call.leaseId;
}

/** The note as a message of its own source kind. */
export function noteMessage() {
  return createUserMessage({
    content: [{ type: 'text', text: NOTE }],
    source: { kind: SOURCE, form: 'snapshot', sections: [{ name: SOURCE, text: NOTE }] },
  });
}

function reminderMessage(question) {
  const text = 'During a pause on this call, the app played this reminder aloud in your voice:\n'
    + `“${question}”\nThe user may be answering it in their next message.`;
  return createUserMessage({
    content: [{ type: 'text', text }],
    source: { kind: SAID_SOURCE, form: 'snapshot', sections: [{ name: SAID_SOURCE, text }] },
  });
}

const json = (value, status = 200) =>
  new Response(JSON.stringify(value), { status, headers: { 'content-type': 'application/json' } });

export default class IosCall {
  static inject = ['connection', 'agents'];

  constructor(ctx) {
    ctx.effect(() => ctx.connection.fetch.register({
      path: `${ROUTE}/state`,
      methods: ['POST'],
      requestBody: 'buffered',
      fetch: async (request) => {
        let body;
        try { body = await request.json(); } catch { body = undefined; }
        const sessionId = typeof body?.sessionId === 'string' ? body.sessionId.trim() : '';
        const callId = typeof body?.callId === 'string' ? body.callId.trim() : '';
        if (!sessionId || !callId || typeof body?.active !== 'boolean') {
          return json({ error: { kind: 'invalid', message: 'expected { sessionId, callId, active }' } }, 400);
        }
        const leaseId = setCall(sessionId, callId, body.active);
        return json({ ok: true, leaseId });
      },
    }), 'ios-call: state');

    ctx.effect(() => ctx.connection.fetch.register({
      path: `${ROUTE}/said`,
      methods: ['POST'],
      requestBody: 'buffered',
      fetch: async (request) => {
        let body;
        try { body = await request.json(); } catch { body = undefined; }
        const { sessionId, leaseId, requestId, text } = body ?? {};
        if (![sessionId, leaseId, requestId, text].every((value) => typeof value === 'string' && value.trim()) || text.length > 500) {
          return json({ error: { kind: 'invalid', message: 'expected { sessionId, leaseId, requestId, text }' } }, 400);
        }
        const call = currentCall(sessionId);
        if (call?.leaseId === leaseId && !call.reminders.has(requestId)) call.reminders.set(requestId, text);
        return json({ ok: true });
      },
    }), 'ios-call: said');

    // Only a turn's first step, and only one that brings new messages: the note is in the
    // history from then on, and a retry (no messages) already has it.
    ctx.on('agent/pre-step', async ({ agent, step, signal }, next) => {
      const decision = await next();
      if (decision.kind === 'reject' || signal?.aborted || step !== 1 || decision.messages.length === 0) return decision;
      const call = currentCall(agent.session.id);
      if (!call) return decision;
      const messages = decision.messages.flatMap((message) => {
        if (message.source.kind !== 'user') return [message];
        const requestId = message.source.rpcId;
        const spoken = call.reminders.get(requestId);
        if (!spoken) return [message];
        // Remember consumption until this lease ends, including if the report is delivered again.
        call.reminders.set(requestId, null);
        return [reminderMessage(spoken), message];
      });
      return { ...decision, messages: [...messages, noteMessage()] };
    });

    ctx.effect(() => () => calls.clear(), 'ios-call: calls');
  }
}
