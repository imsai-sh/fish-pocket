import Intents

/// The Bots and group chats in the top row of the share sheet. iOS puts there the conversations
/// an app says the user sends to (an outgoing `INSendMessageIntent`), ranked by how recently and
/// how often; a tap opens the share extension already on that conversation (`ShareInbox.Target`).
/// Plain conversations stay out: 新对话 is not a conversation someone sends to.
@MainActor
enum ShareSuggestions {
    /// A message went to `sessionId`: tell the system when it is a Bot's chat or a group's.
    static func didSend(in sessionId: String, app: AppModel) {
        let team = app.botTeam
        if let bot = team.bots.first(where: { $0.sessionId == sessionId }), !bot.hidden {
            let image = ShareTargets.avatarURL(of: bot.id).flatMap { try? Data(contentsOf: $0) }.map { INImage(imageData: $0) }
            let person = INPerson(personHandle: INPersonHandle(value: bot.id, type: .unknown), nameComponents: nil,
                                  displayName: bot.name, image: image, contactIdentifier: nil, customIdentifier: bot.id)
            donate(INSendMessageIntent(recipients: [person], outgoingMessageType: .outgoingMessageText, content: nil,
                                       speakableGroupName: nil, conversationIdentifier: ShareInbox.Target.bot(bot.id).conversation,
                                       serviceName: nil, sender: nil, attachments: nil))
        } else if let room = team.rooms.first(where: { $0.sessionId == sessionId }), !room.hidden {
            let members = room.members.compactMap(team.bot).map { bot in
                INPerson(personHandle: INPersonHandle(value: bot.id, type: .unknown), nameComponents: nil,
                         displayName: bot.name, image: nil, contactIdentifier: nil, customIdentifier: bot.id)
            }
            let intent = INSendMessageIntent(recipients: members, outgoingMessageType: .outgoingMessageText, content: nil,
                                             speakableGroupName: INSpeakableString(spokenPhrase: team.name(of: room)),
                                             conversationIdentifier: ShareInbox.Target.room(room.id).conversation,
                                             serviceName: nil, sender: nil, attachments: nil)
            if let data = ShareTargets.avatarURL(ofRoom: room.id, dark: false).flatMap({ try? Data(contentsOf: $0) }) {
                intent.setImage(INImage(imageData: data), forParameterNamed: \.speakableGroupName)
            }
            donate(intent)
        }
    }

    /// Bots and groups gone or hidden leave the row.
    static func forget(_ targets: [ShareInbox.Target]) {
        guard !targets.isEmpty else { return }
        INInteraction.delete(with: targets.map(\.conversation))
    }

    private static func donate(_ intent: INSendMessageIntent) {
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .outgoing
        interaction.groupIdentifier = intent.conversationIdentifier
        interaction.donate(completion: nil)
    }
}
