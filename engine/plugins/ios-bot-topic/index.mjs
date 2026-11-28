import { createHash } from 'node:crypto';
import { mkdir, readFile } from 'node:fs/promises';
import path from 'node:path';
import { writeFileAtomic } from '@deepseek-ai/dsh-atomic-write';
import { createUserMessage } from '@deepseek-ai/dsh-llm';

export const ROUTE = '/api/ios-bot/new-topic';
const SOURCE = 'ios-bot-new-topic';
const invalid = (code) => Object.assign(new Error(code), { code });
const fingerprint = (text) => createHash('sha256').update(text).digest('hex');
const json = (body, status = 200) => Response.json(body, { status });

export default class IosBotTopic {
  static inject = ['connection', 'agents', 'sessionController', 'sessions'];

  constructor(ctx) {
    const handler = ctx.connection.createSharedFetchHandler('/api');
    const pending = new Map();
    const lifetime = new AbortController();
    const directory = () => path.join(process.env.DSH_IOS_DATA, 'bot-topics');
    const file = (id) => path.join(directory(), fingerprint(id) + '.json');

    // Connection admits only the authenticated owner to either exact route.
    async function bot(endpoint, payload = {}) {
      const response = await handler.fetch(new Request('http://localhost/api/bot', {
        method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ endpoint, payload }),
      }), ctx.connection.browserPeer);
      if (!response.ok) throw invalid('unavailable');
      const result = await response.json();
      if (!result.ok) throw invalid('unavailable');
      return result.value;
    }

    async function current(botId) {
      const team = await bot('state');
      if (team.readOnly) throw invalid('read-only');
      const member = team.bots.find(item => item.id === botId);
      if (!member) throw invalid('stale');
      return member;
    }

    async function receipt(id) {
      try { return JSON.parse(await readFile(file(id), 'utf8')); }
      catch (error) { if (error.code !== 'ENOENT') throw error; }
    }

    async function sendFirst(record, requestId, text, clientTimeZone) {
      const sessionId = record.to;
      // DSH deduplicates this ID even if the caller missed the original acknowledgement.
      await ctx.sessionController.prompt({
        sessionId, requestId, mode: 'queue', content: [{ type: 'text', text }], clientTimeZone,
      }, lifetime.signal);
      const session = ctx.sessions.get(sessionId);
      if (session) await ctx.sessions.flush(session);
      await writeFileAtomic(file(requestId), JSON.stringify({ ...record, delivered: true }), { mode: 0o600 });
      return { sessionId };
    }

    async function start({ botId, sessionId, requestId, text, clientTimeZone }, job) {
      const member = await current(botId);
      const previous = await receipt(requestId);
      if (previous) {
        if (previous.botId !== botId || previous.from !== sessionId || previous.digest !== fingerprint(text)) throw invalid('stale');
        if (previous.delivered) return { sessionId: previous.to };
        if (member.sessionId !== previous.to) throw invalid('stale');
        return sendFirst(previous, requestId, text, clientTimeZone);
      }
      if (member.sessionId !== sessionId) throw invalid('stale');
      const { agent } = await ctx.sessionController.resolveAgent(sessionId);
      if (!agent) throw invalid('stale');
      if (agent.status !== 'idle') throw invalid('busy');
      job.turn = Promise.withResolvers();
      // This is the user's first message. A source only this owner route creates
      // routes it at the turn boundary, before a request reaches the old model context.
      // Steer so that even an idle Bot with messages queued behind a rejected turn can switch.
      const queued = agent.inbox.nextTurn[0]?.id;
      agent.steer(createUserMessage({
        content: [{ type: 'text', text }],
        source: { kind: SOURCE, botId, requestId, clientTimeZone, ...(queued ? { queued } : {}) },
      }));
      return job.turn.promise;
    }

    async function submit(body) {
      const { botId, sessionId, requestId, text } = body;
      const existing = pending.get(sessionId);
      if (existing) {
        if (existing.botId === botId && existing.id === requestId && existing.text === text) return existing.result;
        throw invalid('busy');
      }
      const job = { botId, id: requestId, text };
      pending.set(sessionId, job);
      try {
        job.result = start(body, job);
        return await job.result;
      } finally { pending.delete(sessionId); }
    }

    ctx.effect(() => ctx.connection.fetch.register({
      path: ROUTE, methods: ['POST'], requestBody: 'buffered',
      fetch: async (request) => {
        const body = await request.json().catch(() => null);
        if (typeof body?.botId !== 'string' || !body.botId || typeof body.sessionId !== 'string' || !body.sessionId
            || typeof body.requestId !== 'string' || !/^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$/i.test(body.requestId)
            || typeof body.text !== 'string' || !body.text.trim() || typeof body.clientTimeZone !== 'string') {
          return json({ error: 'invalid' }, 400);
        }
        try { new Intl.DateTimeFormat('en', { timeZone: body.clientTimeZone }); }
        catch { return json({ error: 'invalid' }, 400); }
        try { return json(await submit({ ...body, text: body.text.trim() })); }
        catch (error) { return json({ error: error.code ?? 'unavailable' }, 409); }
      },
    }), 'ios-bot-topic: owner route');

    ctx.on('agent/pre-step', async ({ agent, messages }, next) => {
      const first = messages.find(message => message.source?.kind === SOURCE);
      if (!first) return next();
      const from = agent.session.id;
      const { botId, requestId, clientTimeZone } = first.source;
      const text = first.content[0].text;
      const waiting = pending.get(from);
      const job = waiting?.id === requestId && waiting.botId === botId ? waiting : undefined;
      try {
        const member = await current(botId);
        if (member.sessionId !== from) throw invalid('stale');
        // ds-bot opens an independent foreground thread when the Bot is in a turn.
        // Its idle "new part" path instead carries a handoff containing earlier messages.
        await bot('bot-new-part', { botId });
        const fresh = await current(botId);
        if (fresh.sessionId === from || fresh.parts.length || fresh.openParts?.at(-1)?.sessionId !== from) throw invalid('stale');
        await mkdir(directory(), { recursive: true });
        const record = { botId, from, to: fresh.sessionId, digest: fingerprint(text) };
        await writeFileAtomic(file(requestId), JSON.stringify(record), { mode: 0o600 });
        const result = await sendFirst(record, requestId, text, clientTimeZone);
        job?.turn?.resolve(result);
      } catch (error) {
        job?.turn?.reject(error);
      }
      // An opening step claims pending steering plus at most one queued turn. Put
      // that input back in order: starting a clean thread must not wake a blocked
      // request on the old one or drop work already waiting there.
      for (const message of [...messages].reverse()) {
        if (message.source?.kind !== SOURCE) {
          agent.inbox.prepend(message.id === first.source.queued ? 'next-turn' : 'next-step', message);
        }
      }
      return { kind: 'enter', messages: [] };
    }, { prepend: true });

    ctx.on('session/event', (session, event) => {
      if (event.type === 'turn/end') pending.get(session.id)?.turn?.reject(invalid('unavailable'));
    }, { global: true });
    ctx.effect(() => () => {
      lifetime.abort();
      for (const job of pending.values()) job.turn?.reject(invalid('unavailable'));
    }, 'ios-bot-topic: pending requests');
  }
}
