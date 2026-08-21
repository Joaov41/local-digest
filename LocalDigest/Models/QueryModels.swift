import Foundation

struct DateParseResult: Equatable, Sendable {
    let start: Date
    let end: Date
    let phrase: String
}

enum QueryIntent: Equatable, Sendable {
    case inherited
    case explicitSource(SourceKind)
    case explicitTopic

    var hasExplicitBoundary: Bool {
        switch self {
        case .inherited: false
        case .explicitSource, .explicitTopic: true
        }
    }
}

enum QueryMode: Equatable, Sendable {
    case questionAnswer
    case exactLookup
}

enum LookupScope: Equatable, Sendable {
    /// A literal mention/contains lookup keeps every record whose title or
    /// body contains the requested terms.
    case mention
    /// A title lookup only returns exact case-insensitive title matches.
    case title
    /// A topic lookup prefers exact titles and otherwise keeps substantive
    /// lexical body matches.
    case topic
}

struct SearchScope: Hashable, Sendable {
    var selectedSources: Set<SourceKind> = Set(SourceKind.allCases)
    var selectedPerson: String?
}

struct SavedAnswer: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let question: String
    let text: String
    let provider: AIProvider
    let savedAt: Date
}

struct ConversationTurn: Identifiable, Hashable, Sendable {
    let id: UUID
    let question: String
    let answer: String
    let citations: [Citation]
    let provider: AIProvider

    init(id: UUID = UUID(), question: String, answer: String, citations: [Citation], provider: AIProvider) {
        self.id = id
        self.question = question
        self.answer = answer
        self.citations = citations
        self.provider = provider
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case ask
    case search
    case people
    case sources
    case saved

    var id: String { rawValue }
    var title: String {
        switch self {
        case .ask: "Ask"
        case .search: "Search"
        case .people: "People"
        case .sources: "Sources"
        case .saved: "Saved Answers"
        }
    }
    var symbol: String {
        switch self {
        case .ask: "sparkles"
        case .search: "magnifyingglass"
        case .people: "person.2"
        case .sources: "square.stack.3d.up"
        case .saved: "bookmark"
        }
    }
}
