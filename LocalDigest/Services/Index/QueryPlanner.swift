import Foundation

struct QueryPlanner: Sendable {
    private let dateParser: DatePhraseParser
    private let identityResolver: IdentityResolver

    init(dateParser: DatePhraseParser = DatePhraseParser(), identityResolver: IdentityResolver = IdentityResolver()) {
        self.dateParser = dateParser
        self.identityResolver = identityResolver
    }

    func plan(_ question: String, scope: SearchScope = SearchScope(), context: QueryPlan? = nil, referenceDate: Date? = nil) -> QueryPlan {
        let date = dateParser.parse(question, referenceDate: referenceDate)
        let sourceIntent = explicitSource(in: question)
        let personPhrase: String?
        if sourceIntent == nil || sourceIntent?.source == .mail || sourceIntent?.source == .messages {
            personPhrase = extractPersonPhrase(from: question)
        } else {
            personPhrase = nil
        }
        let resolved = personPhrase.map(identityResolver.resolve) ?? []
        let identity = resolved.first
        let stopWords: Set<String> = [
            "what", "did", "tell", "told", "say", "said", "me", "last", "night", "summarize", "our",
            "conversation", "the", "about", "with", "and", "from", "my", "contact", "please", "this",
            "morning", "today", "yesterday", "tomorrow", "week", "message", "messages", "chat", "on", "at",
            "in", "during", "find", "found", "locate", "show", "list", "a", "an", "for", "it", "is", "are",
            "was", "were", "do", "does", "can", "you", "of", "to", "be", "there", "any", "where", "which",
            "mention", "mentions", "contains", "containing", "titled", "called", "named"
        ]
        let dateTokens: Set<String> = [
            "january", "jan", "february", "feb", "march", "mar", "april", "apr", "may", "june", "jun",
            "july", "jul", "august", "aug", "september", "sep", "october", "oct", "november", "nov",
            "december", "dec", "monday", "mon", "tuesday", "tue", "wednesday", "wed", "thursday", "thu",
            "friday", "fri", "saturday", "sat", "sunday", "sun", "next", "previous"
        ]
        let currentKeywords = IdentityResolver.tokens(question).filter {
            !stopWords.contains($0)
                && !dateTokens.contains($0)
                && !(sourceIntent?.excludedTokens.contains($0) ?? false)
                && Int($0) == nil
                && $0.count > 2
        }
        let communicationQuestion = isCommunicationQuestion(question)
        let isExactLookup = isExactLookupQuestion(question)
        let lookupScope = isExactLookup ? lookupScope(for: question) : .topic
        let inheritsConversation = sourceIntent == nil && context?.needsConversationExpansion == true
        let inheritedKeywords = inheritsConversation && currentKeywords.isEmpty ? (context?.keywords ?? []) : []
        let keywords = orderedUnique(currentKeywords + inheritedKeywords)

        let person: String?
        let personTerms: [String]
        if let explicitPerson = identity?.displayName ?? personPhrase {
            person = explicitPerson
            personTerms = identity.map { [$0.displayName] + $0.aliases + $0.handles } ?? [explicitPerson]
        } else if inheritsConversation {
            person = context?.constraints.person
            personTerms = context?.constraints.personTerms ?? []
        } else {
            person = scope.selectedPerson
            personTerms = scope.selectedPerson.map { [$0] } ?? []
        }

        let sources: Set<SourceKind>
        if let sourceIntent {
            sources = [sourceIntent.source]
        } else if communicationQuestion {
            sources = scope.selectedSources == Set(SourceKind.allCases) ? [.mail, .messages] : scope.selectedSources.intersection([.mail, .messages])
        } else if inheritsConversation {
            sources = context?.constraints.sources ?? scope.selectedSources
        } else {
            sources = scope.selectedSources
        }
        let intent = sourceIntent.map { QueryIntent.explicitSource($0.source) } ?? .inherited
        let expandsConversation: Bool
        if sourceIntent != nil {
            expandsConversation = communicationQuestion && (sourceIntent?.source == .mail || sourceIntent?.source == .messages)
        } else {
            expandsConversation = communicationQuestion || context?.needsConversationExpansion == true
        }
        return QueryPlan(
            originalQuestion: question,
            keywords: keywords,
            constraints: SearchConstraints(person: person, personTerms: personTerms, startDate: date?.start ?? (sourceIntent == nil ? context?.constraints.startDate : nil), endDate: date?.end ?? (sourceIntent == nil ? context?.constraints.endDate : nil), sources: sources),
            needsConversationExpansion: expandsConversation,
            ambiguity: resolved.count > 1 ? resolved.map(\.displayName) : [],
            intent: intent,
            mode: isExactLookup ? .exactLookup : .questionAnswer,
            lookupScope: lookupScope
        )
    }

    private func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.lowercased()).inserted }
    }

    private struct SourceIntentMatch: Equatable, Sendable {
        let source: SourceKind
        let excludedTokens: Set<String>
    }

    private func explicitSource(in question: String) -> SourceIntentMatch? {
        let tokens = IdentityResolver.tokens(question)
        func hasAny(_ values: Set<String>) -> Bool { !values.isDisjoint(with: Set(tokens)) }
        func hasSequence(_ sequence: [String]) -> Bool {
            guard !sequence.isEmpty, sequence.count <= tokens.count else { return false }
            return (0...(tokens.count - sequence.count)).contains { index in
                Array(tokens[index..<(index + sequence.count)]) == sequence
            }
        }

        // Contact details are more specific than "email": email address
        // should search Contacts, while email about a calendar searches Mail.
        if hasSequence(["email", "address"]) || hasSequence(["phone", "number"])
            || hasSequence(["contact", "details"]) || hasSequence(["contact", "information"])
            || hasAny(["contacts", "addressbook"]) {
            return SourceIntentMatch(source: .contacts, excludedTokens: ["contact", "contacts", "details", "information", "address", "phone", "number", "email"])
        }
        if hasAny(["email", "emails", "mail", "inbox", "inboxes", "e-mail"]) {
            return SourceIntentMatch(source: .mail, excludedTokens: ["email", "emails", "mail", "inbox", "inboxes", "e-mail"])
        }
        if hasAny(["message", "messages", "text", "texts", "imessage", "imessages", "chat", "chats"]) {
            return SourceIntentMatch(source: .messages, excludedTokens: ["message", "messages", "text", "texts", "imessage", "imessages", "chat", "chats"])
        }
        if hasAny(["note", "notes", "notebook"]) {
            return SourceIntentMatch(source: .notes, excludedTokens: ["note", "notes", "notebook"])
        }
        if hasAny(["reminder", "reminders", "todo", "todos", "task", "tasks"]) {
            return SourceIntentMatch(source: .reminders, excludedTokens: ["reminder", "reminders", "todo", "todos", "task", "tasks"])
        }
        if hasAny(["contact"]) {
            return SourceIntentMatch(source: .contacts, excludedTokens: ["contact"])
        }
        if hasAny(["calendar", "calendars", "event", "events", "meeting", "meetings", "appointment", "appointments", "schedule", "scheduled", "agenda"]) {
            return SourceIntentMatch(source: .calendar, excludedTokens: ["calendar", "calendars", "event", "events", "meeting", "meetings", "appointment", "appointments", "schedule", "scheduled", "agenda"])
        }
        return nil
    }

    private func isExactLookupQuestion(_ question: String) -> Bool {
        let normalized = question.lowercased()
        return [
            "find ", "locate ", "show me ", "which note", "where is ", "list ",
            "any note", "any notes", "any mention", "do i have ", "are there "
        ].contains(where: normalized.contains)
    }

    private func lookupScope(for question: String) -> LookupScope {
        let normalized = question.lowercased()
        if ["titled ", "called ", "named ", "title "].contains(where: normalized.contains) {
            return .title
        }
        if ["mention", "mentions", "contains", "containing", "with "].contains(where: normalized.contains) {
            return .mention
        }
        return .topic
    }

    private func isCommunicationQuestion(_ question: String) -> Bool {
        let normalized = question.lowercased()
        let communicationMarkers = ["conversation", "told me", "tell me", "said", "say", "message", "messages", "chat", "what did"]
        return communicationMarkers.contains(where: normalized.contains)
    }

    private func extractPersonPhrase(from question: String) -> String? {
        let lowered = question.lowercased()
        if let range = lowered.range(of: "did ") {
            let tail = question[range.upperBound...]
            let stopWords = [" tell ", " say ", " mention ", " ask ", " last night", " yesterday", " today", "?"]
            var candidate = String(tail)
            for stopWord in stopWords {
                if let stop = candidate.lowercased().range(of: stopWord) { candidate = String(candidate[..<stop.lowerBound]); break }
            }
            let name = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        let markers = ["contact ", "with ", "from "]
        for marker in markers {
            guard let range = lowered.range(of: marker) else { continue }
            let tail = question[range.upperBound...]
            let candidate = tail.split(whereSeparator: { $0 == "?" || $0 == "." || $0 == "," }).first.map(String.init)
            if let candidate, !candidate.isEmpty {
                return candidate.replacingOccurrences(of: "last night", with: "", options: .caseInsensitive)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }
}
