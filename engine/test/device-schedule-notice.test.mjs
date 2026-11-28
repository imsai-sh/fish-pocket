import test from 'node:test';
import assert from 'node:assert/strict';
import { createUserMessage } from '@deepseek-ai/dsh-llm';
import { explainScheduleDeletion } from '../plugins/ios-native/schedule-notice.mjs';

const message = (kind, text) => createUserMessage({ source: { kind }, content: [{ type: 'text', text }] });
const receipt = '[SCHEDULE CHANGE]\nA scheduled task changed.\nchange: deleted\nschedule_title_json: "old title"';
const deleted = message('schedule', receipt);
const thanks = message('user', '谢谢。');
const catalog = message('skill-catalog', 'skill description');
const enter = messages => ({ kind: 'enter', messages });
const run = (decision, step = 1) => explainScheduleDeletion({ turn: 2, step }, async () => decision);

test('a consumed cancellation identifies the new user input without changing any admitted message', async () => {
  for (const text of ['谢谢。', '请重新设一个提醒。']) {
    const user = message('user', text);
    const decision = enter([deleted, user, catalog]);
    const result = await run(decision);
    assert.deepEqual(result.messages.slice(0, -1), decision.messages);
    const note = result.messages.at(-1);
    assert.equal(note.source.kind, 'ios-native');
    assert.ok(note.content[0].text.includes(JSON.stringify(text)));
    assert.doesNotMatch(note.content[0].text, /old title|skill description/);
  }
});

test('ordinary prompts, scheduler deliveries and quoted notices keep their original admission', async () => {
  for (const input of [
    [thanks], [deleted], [message('user', receipt), thanks],
    [message('schedule', '[SCHEDULED TASK]\n' + receipt), thanks],
    [message('schedule', receipt.replace('change: deleted', 'change: updated')), thanks],
  ]) {
    const decision = enter(input);
    assert.equal(await run(decision), decision);
  }
  const second = enter([deleted, thanks]);
  assert.equal(await run(second, 2), second);
  const rejected = { kind: 'reject' };
  assert.equal(await run(rejected), rejected);
});

test('long and batched user input stays in its original place without a partial quotation', async () => {
  const long = 'long user message '.repeat(100);
  for (const inputs of [[message('user', long)], [thanks, message('user', 'another message')]]) {
    const decision = enter([deleted, ...inputs]);
    const { messages } = await run(decision);
    assert.deepEqual(messages.slice(0, -1), decision.messages);
    assert.doesNotMatch(messages.at(-1).content[0].text, /long user message|another message|谢谢/);
  }
});
