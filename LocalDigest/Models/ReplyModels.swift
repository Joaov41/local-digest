import Foundation

enum ReplyChannel: String, Codable, CaseIterable, Identifiable, Sendable {
    case mail
    case messages

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mail: "Mail"
        case .messages: "Messages"
        }
    }

    var symbol: String {
        switch self {
        case .mail: "envelope"
        case .messages: "message"
        }
    }

    var sourceKind: SourceKind {
        switch self {
        case .mail: .mail
        case .messages: .messages
        }
    }
}

struct ReplyIntent: Equatable, Sendable {
    var recipientPhrase: String?
    var instruction: String?
    var preferredChannel: ReplyChannel?
}

/// Recognizes explicit compose requests such as "reply to Rui with a summary
/// of our conversation". Questions that merely mention replies stay on the
/// read-only answering path.
enum ReplyIntentDetector {
    static func detect(in question: String) -> Bool {
        parse(question) != nil
    }

    static func parse(_ question: String) -> ReplyIntent? {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        guard !isInterrogative(lowered) else { return nil }

        if let match = firstMatch(
            of: #"(?:reply|respond|write back|answer)\s+(?:to\s+)?([^,!?;\n]+?)(?:\s+(?:with|about|saying|telling them|letting them know)\s+(.+))?$"#,
            in: trimmed
        ) {
            guard let recipient = cleanedRecipient(match[1]) else { return nil }
            return ReplyIntent(recipientPhrase: recipient, instruction: cleanedText(match[2]), preferredChannel: channel(in: lowered))
        }

        if let match = firstMatch(
            of: #"send\s+(?:an?\s+)?(email|mail|message|text|imessage|sms)\s+to\s+([^,!?;\n]+?)(?:\s+(?:with|about|saying|telling them|letting them know)\s+(.+))?$"#,
            in: trimmed
        ) {
            guard let recipient = cleanedRecipient(match[2]) else { return nil }
            let keyword = match[1]?.lowercased()
            let requested: ReplyChannel? = (keyword == "email" || keyword == "mail") ? .mail : .messages
            return ReplyIntent(recipientPhrase: recipient, instruction: cleanedText(match[3]), preferredChannel: requested ?? channel(in: lowered))
        }

        if let match = firstMatch(
            of: #"(email|message|text)\s+([^,!?;\n]+?)\s+(?:about|with|saying)\s+(.+)$"#,
            in: trimmed
        ) {
            let keyword = match[1]?.lowercased()
            let requested: ReplyChannel = (keyword == "email") ? .mail : .messages
            return ReplyIntent(recipientPhrase: cleanedRecipient(match[2]), instruction: cleanedText(match[3]), preferredChannel: requested)
        }

        if firstMatch(of: #"\b(draft|compose|write|prepare)\s+(?:an?\s+)?(?:repl(?:y|ies)|response)\b"#, in: lowered) != nil {
            return ReplyIntent(recipientPhrase: nil, instruction: instructionClause(in: lowered), preferredChannel: channel(in: lowered))
        }

        return nil
    }

    private static func isInterrogative(_ lowered: String) -> Bool {
        let words = lowered.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        guard let first = words.first else { return true }
        let interrogativeStarters: Set<String> = ["what", "when", "where", "which", "who", "whose", "why", "how", "did", "does", "do", "is", "are", "was", "were", "has", "have", "had", "will", "would", "can't", "cannot", "should", "could"]
        if interrogativeStarters.contains(String(first)) { return true }
        // "can you reply to rui" is a command; "can rui…" is a question.
        if first == "can" || first == "could" || first == "will" || first == "would" {
            let rest = words.dropFirst().prefix(2).map(String.init)
            if rest.contains(where: { ["you", "u"].contains($0) }) { return false }
            return true
        }
        return false
    }

    private static func instructionClause(in lowered: String) -> String? {
        if let match = firstMatch(of: #"\b(?:with|about|saying)\s+(.+)$"#, in: lowered) {
            return cleanedText(match[1])
        }
        return nil
    }

    private static func channel(in lowered: String) -> ReplyChannel? {
        if lowered.contains("email") || lowered.contains(" e-mail") || lowered.range(of: #"\bmail\b"#, options: .regularExpression) != nil {
            return .mail
        }
        if lowered.contains("imessage") || lowered.contains("sms") || lowered.range(of: #"\b(text|message|chat)\b"#, options: .regularExpression) != nil {
            return .messages
        }
        return nil
    }

    private static func cleanedRecipient(_ value: String?) -> String? {
        guard var text = cleanedText(value) else { return nil }
        while let last = text.last, ".!?".contains(last) {
            text = String(text.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for article in ["the ", "a ", "an ", "my "] where text.lowercased().hasPrefix(article) {
            text = String(text.dropFirst(article.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty ? nil : text
    }

    private static func cleanedText(_ value: String?) -> String? {
        guard var text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func firstMatch(of pattern: String, in text: String) -> [Int: String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range), match.numberOfRanges > 1 else { return nil }
        var captured: [Int: String] = [:]
        for index in 1..<match.numberOfRanges {
            if let groupRange = Range(match.range(at: index), in: text) {
                captured[index] = String(text[groupRange])
            }
        }
        return captured
    }
}

struct ReplyDraft: Identifiable, Equatable, Sendable {
    let id: UUID
    var channel: ReplyChannel
    var recipient: String
    var recipientDisplayName: String?
    var subject: String
    var body: String
    var sourceRecordID: String?
    var evidence: [Citation]

    init(
        id: UUID = UUID(),
        channel: ReplyChannel,
        recipient: String,
        recipientDisplayName: String? = nil,
        subject: String = "",
        body: String,
        sourceRecordID: String? = nil,
        evidence: [Citation] = []
    ) {
        self.id = id
        self.channel = channel
        self.recipient = recipient
        self.recipientDisplayName = recipientDisplayName
        self.subject = subject
        self.body = body
        self.sourceRecordID = sourceRecordID
        self.evidence = evidence
    }
}

/// Mail.app AppleScript reports senders as "Name <address@example.com>",
/// while Contacts handles are bare addresses.
enum EmailAddressExtractor {
    static func extract(from value: String) -> String? {
        if let bracketed = value.range(of: #"<[^<>\s]+@[^<>\s]+\.[^<>\s]+>"#, options: .regularExpression) {
            return String(value[bracketed]).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        }
        if value.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil {
            return value
        }
        return nil
    }

    static func displayName(fromSender value: String?) -> String? {
        guard let value else { return nil }
        guard let bracket = value.range(of: " <") else {
            // A bare address carries no separate display name.
            return extract(from: value) == nil ? (value.isEmpty ? nil : value) : nil
        }
        let name = String(value[..<bracket.lowerBound]).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}

/// Picks which indexed record a reply should target. The reply goes to the
/// most recent record authored by someone other than the user, so a thread
/// the user last wrote in still targets the other participant.
enum ReplyTargetSelector {
    static func select(in hits: [SearchHit], personTerms: [String]) -> SearchHit? {
        let candidates = hits.filter { $0.record.source == .mail || $0.record.source == .messages }
        let incoming = candidates.filter { hit in
            guard let author = hit.record.author else { return true }
            return author.caseInsensitiveCompare("Me") != .orderedSame
        }
        let pool = incoming.isEmpty ? candidates : incoming
        let personMatched = personTerms.isEmpty ? pool : pool.filter { hit in
            personTerms.contains { hit.record.searchableText.localizedCaseInsensitiveContains($0) }
        }
        let finalPool = personMatched.isEmpty ? pool : personMatched
        return finalPool.max { $0.record.timestamp < $1.record.timestamp }
    }
}

enum ReplySendError: LocalizedError, Sendable {
    case invalidRecipient(ReplyChannel)
    case invalidBody(ReplyChannel)
    case permissionDenied(ReplyChannel, String)
    case unavailable(ReplyChannel, String)
    case failed(ReplyChannel, String)

    var errorDescription: String? {
        switch self {
        case .invalidRecipient(let channel):
            "\(channel.title): no sendable address or handle was found for this person. Check the contact card and try again."
        case .invalidBody(let channel):
            "\(channel.title): the reply body is empty."
        case .permissionDenied(let channel, let detail):
            "\(channel.title): \(detail)"
        case .unavailable(let channel, let detail):
            "\(channel.title): \(detail)"
        case .failed(let channel, let detail):
            "\(channel.title): \(detail)"
        }
    }
}
