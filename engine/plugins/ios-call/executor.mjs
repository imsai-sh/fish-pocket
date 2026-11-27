// Delegate the complete batch (including Bot wrappers, approvals and cancellation)
// to DSH. Only a settled, successful end-call may conclude the model's turn.
import { NativeToolExecutor } from '@deepseek-ai/dsh-tool-executor-native';
import { endCallRequest, withEndCallAction } from '../../runtime/end-call.mjs';
import { liveCall } from './index.mjs';

function farewellRequest(call) {
  if (call?.name !== 'bash') return;
  try {
    const args = JSON.parse(call.arguments);
    if (args.run_in_background !== true) return endCallRequest(args.command);
  } catch { /* bash reports its own argument error */ }
}

export class CallToolExecutor extends NativeToolExecutor {
  async execute(input) {
    const { agent, log, calls, signal } = input;
    if (!agent || !log || calls.length !== 1 || calls[0].name !== 'bash') return super.execute(input);
    const session = agent.session;
    const lease = liveCall(session.id);
    const voice = lease?.voice;
    const toolCallId = calls[0].id;
    const proposal = voice?.proposal;
    if (!proposal || voice.turn !== log.turn || proposal.step !== log.step || proposal.toolCallId !== toolCallId) return super.execute(input);
    const request = farewellRequest(calls[0]);
    if (!request || (!request.speech && !proposal.spoken)) return super.execute(input);

    const current = () => !signal.aborted && liveCall(session.id) === lease && lease.voice === voice;
    let invoked = false;
    const batch = await withEndCallAction(speech => {
      if (!current() || speech !== request.speech) return;
      invoked = true;
      return { callId: lease.id, requestId: voice.requestId, toolCallId, text: speech };
    }, () => super.execute(input));
    const outcome = batch.results[0];
    if (invoked && current() && outcome?.callId === toolCallId && !outcome.result.isError
      && outcome.result.value?.kind === 'foreground' && outcome.result.value.exitCode === 0) {
      voice.receipt = { toolCallId, step: log.step };
      return { ...batch, concluded: true };
    }
    return batch;
  }
}

export const inject = ['tools'];
export function apply(ctx) { ctx.tools.setExecutor(new CallToolExecutor(ctx)); }
