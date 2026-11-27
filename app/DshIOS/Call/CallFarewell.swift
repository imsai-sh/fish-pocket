import Foundation

/// Correlates live speech, the model's committed action and the playback it belongs to.
struct CallFarewell {
    struct Action: Equatable {
        let requestId: String
        let turn: Int
        let step: Int
        let toolCallId: String
        let suppliesSpeech: Bool
    }

    /// This only recognizes a proposal. The engine validates the literal shell command and its execution.
    static func suppliesSpeech(_ command: String?) -> Bool? {
        guard let words = command?.split(whereSeparator: { $0.isWhitespace }), words.first == "end-call" else { return nil }
        if words.count == 1 { return false }
        return words[1] == "--say" ? true : nil
    }

    struct Speech: Decodable {
        let callId: String
        let requestId: String
        let toolCallId: String
        let text: String

        private struct Output: Decodable { let farewell: Speech }

        static func read(_ output: String?, call: String) -> Speech? {
            guard let output, output.hasPrefix("{\"farewell\":"), let speech = (try? JSONDecoder().decode(Output.self, from: Data(output.utf8)))?.farewell,
                  speech.toolCallId == call, speech.requestId.hasPrefix("voice-call:\(speech.callId):"),
                  !speech.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return speech
        }
    }

    let callId = UUID().uuidString.lowercased()
    private(set) var requestId: String?
    private(set) var turn: Int?
    private var spokenStep: Int?
    private var action: Action?
    private var completed: Bool?
    private var heard = false
    private var playbackFailed = false
    private var receivedSpeech = false

    mutating func newRequest() -> String {
        cancel()
        let id = "voice-call:\(callId):\(UUID().uuidString.lowercased())"
        requestId = id
        return id
    }

    mutating func admit(_ id: String, turn: Int) -> Bool {
        guard requestId == id, self.turn == nil else { return false }
        self.turn = turn
        return true
    }

    mutating func spoke(step: Int) { spokenStep = step }

    mutating func proposed(turn: Int, step: Int, toolCallId: String, suppliesSpeech: Bool = false) {
        guard completed == nil, let requestId, self.turn == turn, suppliesSpeech || spokenStep == step else { return }
        action = Action(requestId: requestId, turn: turn, step: step, toolCallId: toolCallId, suppliesSpeech: suppliesSpeech)
    }

    mutating func accept(_ speech: Speech, turn: Int, step: Int) -> Bool {
        guard completed == nil, !receivedSpeech, speech.callId == callId, speech.requestId == requestId,
              let action, action.turn == turn, action.step == step, action.toolCallId == speech.toolCallId,
              action.suppliesSpeech else { return false }
        receivedSpeech = true
        return true
    }

    mutating func ended(turn: Int, successfully: Bool) {
        guard completed == nil, self.turn == turn else { return }
        completed = successfully
    }

    mutating func playedAudio() { heard = true }
    mutating func failedToSpeak() { playbackFailed = true }
    func ready(in currentTurn: Int?) -> Action? {
        guard completed == true, heard, !playbackFailed, turn == currentTurn,
              let action, !action.suppliesSpeech || receivedSpeech else { return nil }
        return action
    }

    mutating func cancel() {
        requestId = nil
        turn = nil
        spokenStep = nil
        action = nil
        completed = nil
        heard = false
        playbackFailed = false
        receivedSpeech = false
    }
}
