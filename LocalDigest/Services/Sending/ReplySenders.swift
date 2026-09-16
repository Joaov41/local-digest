import Foundation

protocol ReplySending: Sendable {
    func send(_ draft: ReplyDraft) async throws
}

struct ReplyDispatcher: Sendable {
    func send(_ draft: ReplyDraft) async throws {
        let sender: ReplySending = switch draft.channel {
        case .mail: MailReplySender()
        case .messages: MessagesReplySender()
        }
        try await sender.send(draft)
    }
}

/// Sends through the user's configured Mail.app account via Apple Events.
/// The draft is only dispatched after explicit in-app confirmation.
struct MailReplySender: ReplySending, @unchecked Sendable {
    func send(_ draft: ReplyDraft) async throws {
        guard !draft.recipient.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ReplySendError.invalidRecipient(.mail)
        }
        guard !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReplySendError.invalidBody(.mail)
        }
        try await AppleScriptRunner.requestAutomationPermission(for: .mail)
        let script = Self.sendScript(recipient: draft.recipient, subject: draft.subject, body: draft.body)
        do {
            _ = try await AppleScriptRunner.run(script, source: .mail)
        } catch let error as SourceAdapterError {
            throw Self.mapped(error, channel: .mail)
        }
    }

    static func sendScript(recipient: String, subject: String, body: String) -> String {
        """
        tell application "Mail"
            set outgoingMessage to make new outgoing message with properties {subject:\(AppleScriptLiterals.quoted(subject)), content:\(AppleScriptLiterals.quoted(body)), visible:false}
            tell outgoingMessage
                make new to recipient at end of to recipients with properties {address:\(AppleScriptLiterals.quoted(recipient))}
            end tell
            send outgoingMessage
        end tell
        return "sent"
        """
    }

    private static func mapped(_ error: SourceAdapterError, channel: ReplyChannel) -> ReplySendError {
        switch error {
        case .permissionDenied(_, let message): .permissionDenied(channel, message)
        case .unavailable(_, let message): .unavailable(channel, message)
        }
    }
}

/// Sends through Messages.app. The indexed chat identifier (for example
/// "iMessage;+351912345678" or "sms;+351912345678") is preferred because it
/// targets the exact conversation; a participant handle is the fallback.
struct MessagesReplySender: ReplySending, @unchecked Sendable {
    func send(_ draft: ReplyDraft) async throws {
        guard !draft.recipient.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ReplySendError.invalidRecipient(.messages)
        }
        guard !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReplySendError.invalidBody(.messages)
        }
        try await AppleScriptRunner.requestAutomationPermission(for: .messages)
        let scripts = Self.scripts(recipient: draft.recipient)
        var lastError: Error?
        for script in scripts {
            do {
                _ = try await AppleScriptRunner.run(script, source: .messages)
                return
            } catch let error as SourceAdapterError {
                if case .permissionDenied = error { throw Self.mapped(error, channel: .messages) }
                lastError = Self.mapped(error, channel: .messages)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? ReplySendError.failed(.messages, "Messages could not send the reply.")
    }

    static func scripts(recipient: String) -> [String] {
        if recipient.contains(";") {
            return [chatScript(chatID: recipient, body: ""), participantScript(handle: recipient, body: "")]
        }
        return [participantScript(handle: recipient, body: "")]
    }

    static func chatScript(chatID: String, body: String) -> String {
        """
        tell application "Messages"
            set targetChat to chat id \(AppleScriptLiterals.quoted(chatID))
            send \(AppleScriptLiterals.quoted(body)) to targetChat
        end tell
        return "sent"
        """
    }

    static func participantScript(handle: String, body: String) -> String {
        """
        tell application "Messages"
            set targetService to first service whose service type = iMessage
            set targetParticipant to participant \(AppleScriptLiterals.quoted(handle)) of targetService
            send \(AppleScriptLiterals.quoted(body)) to targetParticipant
        end tell
        return "sent"
        """
    }

    private static func mapped(_ error: SourceAdapterError, channel: ReplyChannel) -> ReplySendError {
        switch error {
        case .permissionDenied(_, let message): .permissionDenied(channel, message)
        case .unavailable(_, let message): .unavailable(channel, message)
        }
    }
}

enum AppleScriptLiterals {
    /// Escapes text for interpolation inside an AppleScript string literal.
    /// Real newlines are legal inside AppleScript strings and are preserved
    /// so multi-line reply bodies survive intact.
    static func quoted(_ value: String) -> String {
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let escaped = normalized
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }
}
