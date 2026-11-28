// Messages routes put scheduler receipts, Skill catalogs and genuine user input in
// the same wire role. Preserve their provenance for the turn that consumes a deletion.
import { createUserMessage } from '@deepseek-ai/dsh-llm';

function isScheduleDeletion(message) {
  const [receipt] = message.content;
  return message.source?.kind === 'schedule' && receipt?.type === 'text'
    && receipt.text.startsWith('[SCHEDULE CHANGE]\n') && receipt.text.includes('\nchange: deleted\n');
}

export async function explainScheduleDeletion({ turn, step }, next) {
  const decision = await next();
  if (step !== 1 || decision.kind !== 'enter' || !decision.messages.some(isScheduleDeletion)) return decision;
  const inputs = decision.messages.filter(message => message.source?.kind === 'user');
  if (!inputs.length) return decision;
  // Quote a short single input in full. For longer or multimodal turns the original
  // messages already carry everything; an excerpt could leave out a new request.
  const blocks = inputs.length === 1 ? inputs[0].content : [];
  const input = blocks.length === 1 && blocks[0].type === 'text' ? blocks[0].text : undefined;
  const attribution = input && input.length <= 256
    ? 'The entire new message from the user in this turn is ' + JSON.stringify(input) + '.'
    : 'Use the new messages from the user in this turn to decide what they requested.';
  const text = 'Phone reminders, turn ' + turn + '. A previously scheduled task has been deleted. '
    + 'The deleted task and its prompt are history. ' + attribution + ' '
    + 'For an acknowledgment, reply in text and finish the turn. Create or restore a phone '
    + 'notification only if the new user input itself asks for one.';
  const note = createUserMessage({
    source: { kind: 'ios-native', form: 'snapshot', sections: [{ name: 'phone reminders', text }] },
    content: [{ type: 'text', text }],
  });
  return { ...decision, messages: [...decision.messages, note] };
}
