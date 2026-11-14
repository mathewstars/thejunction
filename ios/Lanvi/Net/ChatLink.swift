import Foundation

/// Lanvi's answer to one chat message, in the app's own terms.
struct ChatReply: Equatable {
    var text: String
    var crisis: API.CrisisBlock?
    var suggestion: API.SuggestionOut?
}

extension LanviBackend {
    /// The one place the chat talks to the server. Today each message is one
    /// note (`POST /v1/notes`) and the reply is the server's line; when a chat
    /// endpoint arrives, only this function changes. Lanvi's words always come
    /// from the server.
    func sendMessage(id: String, text: String) async throws -> ChatReply {
        let out = try await note(API.NoteIn(id: id, text: String(text.prefix(280))))
        return ChatReply(text: out.reply.text,
                         crisis: out.crisis ? (out.crisisBlock ?? DemoBackend.crisis) : nil,
                         suggestion: out.suggestion)
    }
}

/// One message in today's thread, kept on the phone for the day.
struct ChatMessage: Codable, Equatable, Identifiable {
    enum From: String, Codable { case me, lanvi }
    enum Status: String, Codable { case sent, sending, failed }

    var id: String
    var from: From
    var text: String
    var status: Status = .sent
    var suggestion: API.SuggestionOut? = nil
}

/// Today's conversation. A new day starts fresh with Lanvi's opening line.
struct ChatThread: Codable, Equatable {
    var day: String = ""
    var messages: [ChatMessage] = []
}
