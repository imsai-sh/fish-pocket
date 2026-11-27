import Foundation

@main
enum CallFarewellTests {
    static func main() {
        var call = CallFarewell()
        let first = call.newRequest()
        precondition(!call.admit("other input", turn: 1))
        precondition(call.admit(first, turn: 2))
        call.spoke(step: 1)
        call.proposed(turn: 2, step: 2, toolCallId: "other step")
        call.ended(turn: 2, successfully: true)
        call.proposed(turn: 2, step: 1, toolCallId: "late proposal")
        call.playedAudio()
        precondition(call.ready(in: 2) == nil)

        let second = call.newRequest()
        precondition(call.admit(second, turn: 3))
        call.spoke(step: 1)
        call.proposed(turn: 3, step: 1, toolCallId: "actual")
        call.ended(turn: 3, successfully: true)
        precondition(call.ready(in: 3) == nil) // No audio played.
        call.playedAudio()
        let late = call.ready(in: 3)
        precondition(late?.toolCallId == "actual" && call.ready(in: 4) == nil)
        call.cancel()
        precondition(call.ready(in: 3) != late && call.ready(in: 3) == nil)
        let redial = CallFarewell()
        precondition(redial.callId != call.callId && redial.ready(in: 3) != late)

        let third = call.newRequest()
        precondition(call.admit(third, turn: 4))
        call.spoke(step: 1)
        call.proposed(turn: 4, step: 1, toolCallId: "failed turn")
        call.playedAudio()
        call.ended(turn: 4, successfully: false)
        call.ended(turn: 4, successfully: true)
        precondition(call.ready(in: 4) == nil)

        let last = call.newRequest()
        precondition(call.admit(last, turn: 5))
        call.spoke(step: 1)
        call.proposed(turn: 5, step: 1, toolCallId: "failed synthesis")
        call.playedAudio()
        call.failedToSpeak()
        call.ended(turn: 5, successfully: true)
        precondition(call.ready(in: 5) == nil)
        let utterance = call.newRequest()
        precondition(call.admit(utterance, turn: 6))
        call.proposed(turn: 6, step: 2, toolCallId: "say", suppliesSpeech: true)
        let words = CallFarewell.Speech(callId: call.callId, requestId: utterance, toolCallId: "say", text: "再见。")
        precondition(!call.accept(words, turn: 5, step: 2))
        precondition(call.accept(words, turn: 6, step: 2))
        precondition(!call.accept(words, turn: 6, step: 2)) // A repeated live result must never speak twice.
        call.ended(turn: 6, successfully: true)
        precondition(call.ready(in: 6) == nil)
        call.playedAudio()
        precondition(call.ready(in: 6)?.toolCallId == "say")
        precondition(CallFarewell.suppliesSpeech("end-call  --say '再见'") == true)
        precondition(CallFarewell.suppliesSpeech("echo end-call") == nil)
        print("farewell playback, interruption, failed turns and redial passed")
    }
}
