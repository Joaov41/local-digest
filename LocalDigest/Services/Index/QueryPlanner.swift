import Foundation

/// Optional structured interpretation boundary. Implementations receive only
/// the user's question and return bounded language intent; local planning
/// remains the authority for identities, dates, scope, and retrieval.
protocol QueryIntentInterpreting: Sendable {
    func interpret(question: String, provider: AIProvider, referenceDate: Date) async throws -> StructuredQueryIntent
}

typealias QueryIntentInterpreter = QueryIntentInterpreting

/// Injectable answer-stream seam used by AppStore tests. The production
/// implementation is FoundationModelService; it carries evidence only after
/// local retrieval has succeeded.
protocol AnswerStreaming: Sendable {
    func stream(
        question: String,
        evidence: [SearchHit],
        provider: AIProvider,
        intent: QueryIntent,
        referenceDate: Date,
        previousAnswer: String?,
        requireNewDetails: Bool,
        evidenceOrdering: QueryOrdering
    ) async -> AsyncThrowingStream<String, Error>
}

struct QueryPlanner: Sendable {
    fileprivate let dateParser: DatePhraseParser
    private let identityResolver: IdentityResolver

    init(dateParser: DatePhraseParser = DatePhraseParser(), identityResolver: IdentityResolver = IdentityResolver()) {
        self.dateParser = dateParser
        self.identityResolver = identityResolver
    }

    func plan(_ question: String, scope: SearchScope = SearchScope(), context: QueryPlan? = nil, referenceDate: Date? = nil, surface: QuerySurface = .ask) -> QueryPlan {
        let date = dateParser.parse(question, referenceDate: referenceDate)
        let sourceIntent = explicitSource(in: question)
        let explicitPersonPhrase: String?
        if sourceIntent == nil || sourceIntent?.source == .mail || sourceIntent?.source == .messages {
            explicitPersonPhrase = extractPersonPhrase(from: question, sourceIntent: sourceIntent).flatMap(Self.withoutPronouns)
        } else {
            explicitPersonPhrase = nil
        }
        // Elliptical continuations intentionally change only the person
        // boundary while retaining the prior topic, for example "And
        // Cachinhos?" after a shipment question. Complete replacement
        // questions continue through explicitPersonPhrase and reset topics
        // when the contact changes.
        let continuationPersonPhrase = context != nil
            ? extractContinuationPersonPhrase(from: question)
            : nil
        let personPhrase = explicitPersonPhrase ?? continuationPersonPhrase
        let isContinuationPersonChange = explicitPersonPhrase == nil && continuationPersonPhrase != nil
        let resolved = personPhrase.map(identityResolver.resolveWithConservativeFuzzy) ?? []
        // A person slot is safe only when it resolves to one consolidated
        // identity.  Keep an ambiguous or unknown phrase as ordinary query
        // language instead of silently turning it into a person filter.
        let identity = resolved.count == 1 ? resolved.first : nil
        let recency = recencyRequest(in: question, sourceIntent: sourceIntent)
        let stopWords: Set<String> = [
            "what", "did", "tell", "told", "say", "said", "me", "night", "summarize", "our",
            "conversation", "the", "about", "with", "and", "from", "my", "contact", "please", "this",
            "morning", "today", "yesterday", "tomorrow", "week", "message", "messages", "chat", "on", "at",
            "in", "during", "find", "found", "locate", "show", "list", "a", "an", "for", "it", "is", "are",
            "was", "were", "do", "does", "can", "you", "of", "to", "be", "there", "any", "where", "which",
            "mention", "mentions", "contains", "containing", "titled", "called", "named",
            "he", "she", "they", "him", "her", "them", "his", "hers", "their", "theirs", "that", "those",
            "go", "dig", "going", "deeper", "more", "elaborate", "expand", "continue", "else",
            "detail", "details", "context", "info", "catch", "catchup", "caught", "up", "anything",
            "new", "sent", "recently", "few"
        ]
        var dateTokens: Set<String> = [
            "january", "jan", "february", "feb", "march", "mar", "april", "apr", "may", "june", "jun",
            "july", "jul", "august", "aug", "september", "sep", "october", "oct", "november", "nov",
            "december", "dec", "monday", "mon", "tuesday", "tue", "wednesday", "wed", "thursday", "thu",
            "friday", "fri", "saturday", "sat", "sunday", "sun", "next", "previous"
        ]
        dateTokens.formUnion(DatePhraseParser.temporalTypoTokens)
        let resolvedPersonTokens = Set(
            ((identity.map { [$0.displayName] + $0.aliases + $0.handles } ?? []) + (resolved.isEmpty ? [] : [personPhrase].compactMap { $0 }))
                .flatMap(IdentityResolver.tokens)
        )
        let questionTokens = IdentityResolver.tokens(question)
        let communicationGrammarVerbIndices = communicationGrammarVerbIndices(
            in: questionTokens,
            resolvedPersonTokens: resolvedPersonTokens
        )
        let currentKeywords = questionTokens.enumerated().filter { index, token in
            !stopWords.contains(token)
                && !dateTokens.contains(token)
                && !recency.excludedTokenIndices.contains(index)
                && !(date != nil && ["last", "night", "week"].contains(token))
                && !communicationGrammarVerbIndices.contains(index)
                && !resolvedPersonTokens.contains(token)
                && !(sourceIntent?.excludedTokens.contains(token) ?? false)
                && Int(token) == nil
                && token.count > 2
        }.map(\.element)
        let communicationQuestion = isCommunicationQuestion(question)
        let isExactLookup = isExactLookupQuestion(question, surface: surface)
        let lookupScope = isExactLookup ? lookupScope(for: question) : .topic
        // A newly stated date replaces the prior date window, while the
        // conversational person/source/topic context remains useful.
        let isFollowUp = isFollowUpQuestion(question, hasSourceIntent: sourceIntent != nil, hasDatePhrase: date != nil)
        // Once a conversation exists, every typed submission remains in that
        // conversation. Explicit source/date/person constraints refine the
        // new turn, while the planner still carries compatible context.
        let inheritsConversation = context != nil
        let canInheritTopic = sourceIntent == nil || sourceIntent?.source == .mail || sourceIntent?.source == .messages
        let personBoundaryAllowsTopicInheritance: Bool
        if isContinuationPersonChange {
            personBoundaryAllowsTopicInheritance = true
        } else if personPhrase == nil {
            personBoundaryAllowsTopicInheritance = true
        } else if let identity, let priorPerson = context?.constraints.person {
            // An explicitly named person keeps a prior topic only when it is
            // the same consolidated identity. Switching contacts starts a
            // fresh topic search instead of carrying irrelevant FTS terms.
            personBoundaryAllowsTopicInheritance = IdentityResolver.normalize(identity.displayName)
                == IdentityResolver.normalize(priorPerson)
        } else if context?.constraints.person != nil {
            // An unresolved or ambiguous person cannot inherit a topic that
            // was scoped to the prior contact.
            personBoundaryAllowsTopicInheritance = false
        } else {
            // With no prior person scope, an explicit person can still refine
            // the existing conversational topic.
            personBoundaryAllowsTopicInheritance = true
        }
        let inheritedKeywords = inheritsConversation && canInheritTopic && personBoundaryAllowsTopicInheritance && (currentKeywords.isEmpty || isFollowUp)
            ? (context?.keywords ?? []).filter { !["latest", "newest", "recent", "most", "last"].contains($0) }
            : []
        let keywords = orderedUnique(currentKeywords + inheritedKeywords)
        let effectiveOrdering = recency.ordering == .relevance ? (context?.ordering ?? .relevance) : recency.ordering
        let effectiveCount = recency.count ?? (effectiveOrdering == .relevance ? nil : context?.requestedResultCount)
        let reference = referenceDate ?? Date()
        let inheritedStart = context?.constraints.startDate
        let chronologicalStart: Date?
        if effectiveOrdering == .upcomingFirst, date == nil {
            chronologicalStart = max(inheritedStart ?? reference, reference)
        } else {
            chronologicalStart = inheritedStart
        }

        let person: String?
        let personTerms: [String]
        if let identity {
            person = identity.displayName
            personTerms = [identity.displayName] + identity.aliases + identity.handles
        } else if personPhrase != nil {
            // The phrase was explicitly supplied on this turn, but did not
            // resolve uniquely.  It must replace an inherited person without
            // becoming an implicit author/participant constraint.
            person = nil
            personTerms = []
        } else if inheritsConversation && canInheritTopic {
            person = context?.constraints.person
            personTerms = context?.constraints.personTerms ?? []
        } else {
            person = scope.selectedPerson
            personTerms = scope.selectedPerson.map { [$0] } ?? []
        }

        let sources: Set<SourceKind>
        if let sourceIntent {
            // SearchScope is an absolute boundary, including for explicit
            // deterministic source words.
            sources = Set([sourceIntent.source]).intersection(scope.selectedSources)
        } else if inheritsConversation {
            sources = (context?.constraints.sources ?? scope.selectedSources).intersection(scope.selectedSources)
        } else if communicationQuestion {
            sources = scope.selectedSources == Set(SourceKind.allCases) ? [.mail, .messages] : scope.selectedSources.intersection([.mail, .messages])
        } else {
            sources = scope.selectedSources
        }
        let intent = sourceIntent.map { QueryIntent.explicitSource($0.source) } ?? .inherited
        let expandsConversation: Bool
        if sourceIntent != nil {
            expandsConversation = !sources.isEmpty && communicationQuestion && (sourceIntent?.source == .mail || sourceIntent?.source == .messages)
        } else {
            expandsConversation = communicationQuestion || context?.needsConversationExpansion == true
        }

        // A vague follow-up such as "go deeper" carries no new constraints of
        // its own. It continues the previous question wholesale instead of
        // degrading into an empty, unconstrained search.
        if context != nil, sourceIntent == nil, date == nil, personPhrase == nil, identity == nil,
           currentKeywords.isEmpty, Self.looksLikeFollowUp(question), let context {
            let followUpPerson = scope.selectedPerson ?? context.constraints.person
            let followUpPersonTerms = scope.selectedPerson.map { [$0] } ?? context.constraints.personTerms
            return QueryPlan(
                originalQuestion: question,
                keywords: context.keywords,
                constraints: SearchConstraints(
                    person: followUpPerson,
                    personTerms: followUpPersonTerms,
                    startDate: context.constraints.startDate,
                    endDate: context.constraints.endDate,
                    sources: context.constraints.sources.intersection(scope.selectedSources)
                ),
                needsConversationExpansion: true,
                ambiguity: [],
                intent: .inherited,
                mode: .questionAnswer,
                lookupScope: .topic,
                continuesConversation: true,
                ordering: context.ordering,
                requestedResultCount: context.requestedResultCount,
                retrievalPolicy: context.retrievalPolicy,
                hasUnresolvedPersonPhrase: context.hasUnresolvedPersonPhrase,
                surface: surface
            )
        }

        // A selected person is also a hard scope boundary.  It is applied
        // after local identity resolution so a query cannot escape a People
        // view filter by naming another contact.
        let scopedPerson: String?
        let scopedPersonTerms: [String]
        if let selectedPerson = scope.selectedPerson {
            scopedPerson = selectedPerson
            scopedPersonTerms = [selectedPerson]
        } else {
            scopedPerson = person
            scopedPersonTerms = personTerms
        }

        let hasUnresolvedPersonPhrase = personPhrase != nil && identity == nil && resolved.isEmpty
        let retrievalPolicy = Self.retrievalPolicy(
            surface: surface,
            mode: isExactLookup ? .exactLookup : .questionAnswer,
            lookupScope: lookupScope,
            hasUnresolvedPersonPhrase: hasUnresolvedPersonPhrase,
            hasResolvedPersonBoundary: identity != nil || scope.selectedPerson != nil || context?.constraints.person != nil,
            hasDateBoundary: date != nil || context?.constraints.startDate != nil,
            hasSourceBoundary: sourceIntent != nil
        )
        return QueryPlan(
            originalQuestion: question,
            keywords: keywords,
            constraints: SearchConstraints(person: scopedPerson, personTerms: scopedPersonTerms, startDate: date?.start ?? chronologicalStart, endDate: date?.end ?? context?.constraints.endDate, sources: sources),
            needsConversationExpansion: expandsConversation,
            ambiguity: resolved.count > 1 ? orderedUnique(resolved.map(\.displayName)) : [],
            intent: intent,
            mode: isExactLookup ? .exactLookup : .questionAnswer,
            lookupScope: lookupScope,
            continuesConversation: context != nil,
            ordering: effectiveOrdering,
            requestedResultCount: effectiveCount,
            retrievalPolicy: retrievalPolicy,
            hasUnresolvedPersonPhrase: hasUnresolvedPersonPhrase,
            surface: surface
        )
    }

    /// Applies a model-supplied language interpretation to the deterministic
    /// plan. The model supplies the primary language interpretation while
    /// deterministic planning validates scope, identities, and dates and
    /// provides safe fallbacks. The model cannot introduce handles,
    /// timestamps, SQL, or a source outside SearchScope.
    func plan(
        _ question: String,
        scope: SearchScope = SearchScope(),
        context: QueryPlan? = nil,
        referenceDate: Date? = nil,
        structuredIntent: StructuredQueryIntent,
        surface: QuerySurface = .ask
    ) -> QueryPlan {
        let base = plan(question, scope: scope, context: context, referenceDate: referenceDate, surface: surface)
        let reference = referenceDate ?? Date()
        let modelDate = structuredIntent.timeframePhrase.flatMap {
            dateParser.parse($0, referenceDate: reference)
        }

        var constraints = base.constraints
        let sourceIntent = explicitSource(in: question)
        if sourceIntent == nil, let modelSources = structuredIntent.sources {
            // Model source intent fills an absent deterministic source but can
            // never escape SearchScope. An explicit source on this turn wins
            // even if a model guessed a different source.
            constraints.sources = modelSources.intersection(scope.selectedSources)
        } else {
            constraints.sources = constraints.sources.intersection(scope.selectedSources)
        }

        if let modelDate {
            constraints.startDate = modelDate.start
            constraints.endDate = modelDate.end
        }

        var ambiguity = base.ambiguity
        var ambiguousPersonTokens: Set<String> = []
        let deterministicPersonPhrase = extractPersonPhrase(from: question, sourceIntent: sourceIntent).flatMap(Self.withoutPronouns)
        // A locally resolved person is authoritative. An unresolved rule
        // phrase is only a candidate and may be repaired by a copied model
        // phrase that resolves uniquely.
        let hasDeterministicPerson = deterministicPersonPhrase != nil && !base.hasUnresolvedPersonPhrase
        var resolvedModelPerson = false
        var hasUnresolvedPersonPhrase = base.hasUnresolvedPersonPhrase
        if !hasDeterministicPerson, let phrase = structuredIntent.personPhrase,
           let cleanPhrase = Self.withoutPronouns(phrase) {
            let resolved = identityResolver.resolveWithConservativeFuzzy(cleanPhrase)
            if resolved.count == 1, let identity = resolved.first {
                constraints.person = identity.displayName
                constraints.personTerms = [identity.displayName] + identity.aliases + identity.handles
                ambiguity = []
                resolvedModelPerson = true
                hasUnresolvedPersonPhrase = false
            } else if resolved.count > 1 {
                constraints.person = nil
                constraints.personTerms = []
                ambiguity = orderedUnique(resolved.map(\.displayName))
                ambiguousPersonTokens = Set(IdentityResolver.tokens(cleanPhrase))
                hasUnresolvedPersonPhrase = true
            } else {
                // An unresolved model phrase is an explicit new-turn person
                // field. Clear inherited person state and retain its words
                // as ordinary FTS terms below, never as a person filter.
                constraints.person = nil
                constraints.personTerms = []
                hasUnresolvedPersonPhrase = true
            }
        }

        let modelPersonTokens = Set(structuredIntent.personPhrase.flatMap(IdentityResolver.tokens) ?? [])
        let modelSourceTokens = Set((structuredIntent.sources ?? []).flatMap { sourceWords(for: $0) })
        let modelDateTokens = Set(structuredIntent.timeframePhrase.flatMap(IdentityResolver.tokens) ?? [])
        let removedModelTokens = modelPersonTokens.union(modelSourceTokens).union(modelDateTokens)
        let hasModelSignal = structuredIntent.sources != nil
            || structuredIntent.personPhrase.map { !$0.isEmpty } == true
            || structuredIntent.timeframePhrase.map { !$0.isEmpty } == true
            || structuredIntent.ordering != nil
            || structuredIntent.requestedCount != nil
        var keywords: [String]
        if let topic = structuredIntent.topicPhrase, !topic.isEmpty {
            keywords = IdentityResolver.tokens(topic).filter { token in
                token.count > 2
                    && !removedModelTokens.contains(token)
                    && Int(token) == nil
            }
        } else if hasModelSignal {
            keywords = []
        } else {
            keywords = base.keywords.filter { !removedModelTokens.contains($0) }
        }
        if !hasDeterministicPerson, let phrase = structuredIntent.personPhrase,
           let cleanPhrase = Self.withoutPronouns(phrase),
           !resolvedModelPerson, ambiguity.isEmpty {
            // An unknown model person is still literal language, not an
            // author constraint. Keeping it searchable avoids broadening a
            // free-form request into an unrelated corpus-wide query.
            keywords.append(contentsOf: IdentityResolver.tokens(cleanPhrase).filter {
                $0.count > 2
                    && !removedModelTokens.contains($0)
                    && Int($0) == nil
            })
        }
        keywords.removeAll { ambiguousPersonTokens.contains($0) }

        let currentRecency = recencyRequest(in: question, sourceIntent: sourceIntent)
        let explicitCount = IdentityResolver.tokens(question).compactMap(Int.init).first
        let hasCurrentOrdering = currentRecency.ordering != .relevance
        let rulesWin = explicitCount != nil && hasCurrentOrdering
        let ordering = rulesWin
            ? currentRecency.ordering
            : (structuredIntent.ordering ?? (hasCurrentOrdering ? currentRecency.ordering : nil) ?? base.ordering)
        let requestedCount: Int?
        if rulesWin {
            requestedCount = currentRecency.count
        } else {
            requestedCount = structuredIntent.requestedCount
                ?? currentRecency.count
                ?? (ordering != .relevance ? 5 : base.requestedResultCount)
        }

        let modelSingleSource = structuredIntent.sources?.count == 1
        let intent: QueryIntent
        if base.intent.hasExplicitBoundary {
            intent = base.intent
        } else if modelSingleSource,
                  let source = structuredIntent.sources?.first,
                  constraints.sources.contains(source) {
            intent = .explicitSource(source)
        } else {
            intent = base.intent
        }
        let modelCommunication = constraints.sources.contains(where: { $0 == .mail || $0 == .messages })
        let expandsConversation = base.needsConversationExpansion || modelCommunication

        if let selectedPerson = scope.selectedPerson {
            // SearchScope remains authoritative after every model merge.
            constraints.person = selectedPerson
            constraints.personTerms = [selectedPerson]
            ambiguity = []
            hasUnresolvedPersonPhrase = false
        }

        keywords = orderedUnique(keywords)
        if keywords.isEmpty,
           ordering == .relevance,
           constraints.person == nil,
           constraints.startDate == nil,
           constraints.sources.isEmpty {
            keywords = base.keywords
        }

        // A unique local identity is the only model-person result that may
        // replace a person. The flag documents that this branch is deliberate
        // and keeps the safety rule visible at the merge point.
        _ = resolvedModelPerson
        _ = modelDate
        let retrievalPolicy = Self.retrievalPolicy(
            surface: surface,
            mode: base.mode,
            lookupScope: base.lookupScope,
            hasUnresolvedPersonPhrase: hasUnresolvedPersonPhrase,
            hasResolvedPersonBoundary: constraints.person != nil,
            hasDateBoundary: constraints.startDate != nil,
            hasSourceBoundary: sourceIntent != nil || structuredIntent.sources != nil
        )

        return QueryPlan(
            originalQuestion: base.originalQuestion,
            keywords: keywords,
            constraints: SearchConstraints(
                person: constraints.person,
                personTerms: constraints.personTerms,
                startDate: constraints.startDate,
                endDate: constraints.endDate,
                sources: constraints.sources
            ),
            needsConversationExpansion: expandsConversation,
            ambiguity: ambiguity,
            intent: intent,
            mode: base.mode,
            lookupScope: base.lookupScope,
            continuesConversation: base.continuesConversation || (structuredIntent.continuesConversation && context != nil),
            ordering: ordering,
            requestedResultCount: requestedCount,
            retrievalPolicy: retrievalPolicy,
            hasUnresolvedPersonPhrase: hasUnresolvedPersonPhrase,
            surface: surface
        )
    }

    private static func retrievalPolicy(
        surface: QuerySurface,
        mode: QueryMode,
        lookupScope: LookupScope,
        hasUnresolvedPersonPhrase: Bool,
        hasResolvedPersonBoundary: Bool,
        hasDateBoundary: Bool,
        hasSourceBoundary: Bool
    ) -> QueryRetrievalPolicy {
        guard surface == .ask, mode == .questionAnswer, lookupScope == .topic else { return .literalKeywords }
        // An explicit but unresolved person remains lexical language. This
        // prevents a date-only fallback from broadening across other people.
        guard !hasUnresolvedPersonPhrase else { return .literalKeywords }
        guard hasResolvedPersonBoundary || hasDateBoundary || hasSourceBoundary else { return .literalKeywords }
        return .scopedSemanticEvidence
    }

    private func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.lowercased()).inserted }
    }

    private func recencyRequest(in question: String, sourceIntent: SourceIntentMatch?) -> (ordering: QueryOrdering, count: Int?, excludedTokenIndices: Set<Int>) {
        let tokens = IdentityResolver.tokens(question)
        let count = tokens.compactMap(Int.init).first.map { min(50, max(1, $0)) }
        let source = sourceIntent?.source
        let sourceTokens: Set<String> = ["email", "emails", "mail", "message", "messages", "note", "notes", "calendar", "event", "events", "reminder", "reminders"]
        let hasSupportedSource = source.map { [.mail, .messages, .notes, .calendar, .reminders].contains($0) } ?? !sourceTokens.isDisjoint(with: Set(tokens))
        guard hasSupportedSource else { return (.relevance, nil, []) }
        var sourceNouns: Set<String>
        var pluralNouns: Set<String>
        switch source {
        case .mail: sourceNouns = ["email", "emails", "mail"]; pluralNouns = ["emails"]
        case .messages:
            sourceNouns = ["message", "messages"]
            pluralNouns = ["messages", "texts", "imessages", "chats"]
            pluralNouns.formUnion(Self.communicationSourceTypoAllowlist.keys)
        case .notes: sourceNouns = ["note", "notes"]; pluralNouns = ["notes"]
        case .calendar: sourceNouns = ["calendar", "event", "events"]; pluralNouns = ["events"]
        case .reminders: sourceNouns = ["reminder", "reminders"]; pluralNouns = ["reminders"]
        default: sourceNouns = sourceTokens; pluralNouns = []
        }
        if let source {
            sourceNouns.formUnion(sourceWords(for: source))
        }
        let sourceIndex = tokens.firstIndex(where: { sourceNouns.contains($0) }) ?? tokens.count
        let structuralOperators = structuralRecencyOperatorIndices(in: tokens, sourceIndex: sourceIndex, source: source, count: count)
        let hasNewest = structuralOperators.contains { index in
            guard let canonical = canonicalRecencyToken(tokens[index]) else { return false }
            return ["latest", "newest", "recent", "last"].contains(canonical)
        }
        let futureSource = source.map { $0 == .calendar || $0 == .reminders } ?? (tokens.contains("calendar") || tokens.contains("event") || tokens.contains("events") || tokens.contains("reminder") || tokens.contains("reminders"))
        let hasUpcoming = futureSource && structuralOperators.contains { index in
            guard let canonical = canonicalRecencyToken(tokens[index]) else { return false }
            return ["upcoming", "next"].contains(canonical)
        }
        let hasSummaryRequest = tokens.contains("summarize") || tokens.contains("summary")
        let hasSummarizeCount = count != nil && hasSummaryRequest
        let hasCommunicationSummary = hasSummaryRequest && (source == .mail || source == .messages)
        guard hasNewest || hasUpcoming || hasSummarizeCount || hasCommunicationSummary else { return (.relevance, nil, []) }
        let defaultCount = pluralNouns.contains(tokens.first(where: { sourceNouns.contains($0) }) ?? "") ? 5 : 1
        if hasUpcoming { return (.upcomingFirst, count ?? 5, structuralOperators) }
        return (.newestFirst, count ?? defaultCount, structuralOperators)
    }

    /// Removes only question-grammar uses of ask/asked. The same words must
    /// remain searchable when they are the requested topic, such as
    /// "messages mentioning asked" or "about being asked".
    private func communicationGrammarVerbIndices(in tokens: [String], resolvedPersonTokens: Set<String>) -> Set<Int> {
        let verbs: Set<String> = ["ask", "asked", "asks", "asking"]
        let auxiliaries: Set<String> = ["did", "does", "do", "can", "could", "would", "will", "was", "were", "is", "are"]
        let recipients: Set<String> = ["me", "you", "us", "him", "her", "them"]
        let questionMarkers: Set<String> = ["what", "who", "when", "where", "which", "why", "how"]
        var indices = Set<Int>()
        for (index, token) in tokens.enumerated() where verbs.contains(token) {
            let previous = index > 0 ? tokens[index - 1] : nil
            let next = index + 1 < tokens.count ? tokens[index + 1] : nil
            let followsPerson = previous.map(resolvedPersonTokens.contains) ?? false
            let followsAuxiliary = previous.map(auxiliaries.contains) ?? false
            let hasQuestionMarker = tokens.contains(where: questionMarkers.contains)
            let hasRecipient = next.map(recipients.contains) ?? false
            // An auxiliary alone is not enough: "messages mentioning was
            // asked" is a valid topic search. Require an interrogative
            // question shape unless a resolved person/recipient makes the
            // communication verb structural.
            guard (hasQuestionMarker && followsAuxiliary)
                || (followsPerson && (hasRecipient || hasQuestionMarker)) else { continue }
            indices.insert(index)
        }
        return indices
    }

    /// Returns recency/future operators only when the operator is structurally
    /// attached to the source noun. This keeps "latest release messages" and
    /// similar topic phrases searchable as literal text.
    private func structuralRecencyOperatorIndices(in tokens: [String], sourceIndex: Int, source: SourceKind?, count: Int?) -> Set<Int> {
        guard sourceIndex > 0 else { return [] }
        let futureSource = source.map { $0 == .calendar || $0 == .reminders } ?? (tokens.contains("calendar") || tokens.contains("event") || tokens.contains("events") || tokens.contains("reminder") || tokens.contains("reminders"))
        let recognized: Set<String> = ["latest", "latests", "lastest", "newest", "recent", "most", "last", "upcoming", "next"]
        let qualifierTokens: Set<String> = ["received", "incoming", "unread", "new"]
        var result = Set<Int>()
        for index in 0..<sourceIndex {
            guard let canonical = canonicalRecencyToken(tokens[index]) else { continue }
            if ["upcoming", "next"].contains(canonical), !futureSource { continue }
            if canonical == "last", count == nil { continue }
            let between = tokens[(index + 1)..<sourceIndex]
            guard between.allSatisfy({
                Int($0) != nil || recognized.contains($0) || qualifierTokens.contains($0)
            }) else { continue }
            result.insert(index)
            for (offset, token) in between.enumerated() where qualifierTokens.contains(token) {
                result.insert(index + 1 + offset)
            }
            // "most" is part of the "most recent" operator, but is not a
            // recency operator on its own and therefore needs to be removed
            // from FTS alongside the adjacent "recent" token.
            if canonical == "recent", index > 0, tokens[index - 1] == "most" {
                result.insert(index - 1)
            }
        }
        return result
    }

    private func canonicalRecencyToken(_ token: String) -> String? {
        switch token {
        case "latest", "latests", "lastest": return "latest"
        case "newest": return "newest"
        case "recent": return "recent"
        case "most": return "most"
        case "last": return "last"
        case "upcoming": return "upcoming"
        case "next": return "next"
        default: return nil
        }
    }

    private func isFollowUpQuestion(_ question: String, hasSourceIntent: Bool, hasDatePhrase: Bool) -> Bool {
        guard !hasSourceIntent, !hasDatePhrase else { return false }
        let lowered = question.lowercased()
        let markers = ["tell me more", "more about", "go deeper", "elaborate", "expand on", "what else", "anything else", "any more", "continue"]
        if markers.contains(where: { lowered.contains($0) }) { return true }
        let pronouns: Set<String> = ["he", "she", "they", "him", "her", "them", "his", "hers", "their", "theirs"]
        return IdentityResolver.tokens(lowered).contains { pronouns.contains($0) }
    }

    static func withoutPronouns(_ phrase: String) -> String? {
        let pronouns: Set<String> = ["he", "she", "they", "him", "her", "them", "it", "his", "hers", "their", "theirs", "i", "you"]
        let kept = phrase.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .filter { !pronouns.contains($0.lowercased()) }
            .joined(separator: " ")
        return kept.isEmpty ? nil : kept
    }

    static func looksLikeFollowUp(_ question: String) -> Bool {
        let lowered = question.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else { return false }
        let patterns = [
            #"^(go|dig|going) deeper\b"#,
            #"^tell me more\b"#,
            #"^(more|deeper|elaborate|expand|continue|why\??|how so\??|examples?\??)\??$"#,
            #"^what (about|else)\b.*$"#,
            #"^(any|anything) (more|else)\b"#,
            #"\b(more (detail|details|context|info)|go deeper|dig deeper|elaborate on (that|this|it)|expand on (that|this|it))\b"#
        ]
        return patterns.contains { lowered.range(of: $0, options: .regularExpression) != nil }
    }

    /// A deliberately small communication-source typo list. These are common
    /// one-edit omissions/duplications plus the observed "messas" typo; the
    /// list is consulted only in a source-shaped grammar slot below.
    private static let communicationSourceTypoAllowlist: [String: SourceKind] = [
        "messas": .messages,
        "mesage": .messages,
        "mesages": .messages,
        "messags": .messages,
        "messsage": .messages,
        "messsages": .messages,
        "messagees": .messages
    ]

    private func sourceWords(for source: SourceKind) -> Set<String> {
        switch source {
        case .mail:
            return ["email", "emails", "mail", "inbox", "inboxes", "e-mail"]
        case .messages:
            return Set(["message", "messages", "text", "texts", "imessage", "imessages", "chat", "chats"])
                .union(Self.communicationSourceTypoAllowlist.keys)
        case .notes:
            return ["note", "notes", "notebook"]
        case .calendar:
            return ["calendar", "calendars", "event", "events", "meeting", "meetings", "appointment", "appointments", "schedule", "scheduled", "agenda"]
        case .reminders:
            return ["reminder", "reminders", "todo", "todos", "task", "tasks"]
        case .contacts:
            return ["contact", "contacts", "addressbook"]
        }
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
        if let typo = fuzzyCommunicationSource(in: tokens) {
            return SourceIntentMatch(
                source: typo.source,
                excludedTokens: ["message", "messages", "text", "texts", "imessage", "imessages", "chat", "chats", typo.token]
            )
        }
        return nil
    }

    private func fuzzyCommunicationSource(in tokens: [String]) -> (token: String, source: SourceKind)? {
        let grammarWords: Set<String> = [
            "summarize", "summary", "show", "list", "get", "give", "find", "what", "did", "tell", "said",
            "my", "our", "the", "latest", "newest", "recent", "last", "this", "these", "please", "can", "could", "would"
        ]
        let boundaryWords: Set<String> = [
            "of", "from", "with", "for", "on", "in", "during", "about", "regarding", "today", "yesterday",
            "tomorrow", "this", "last", "next", "week", "month", "night", "morning"
        ]
        for (index, token) in tokens.enumerated() {
            guard let source = Self.communicationSourceTypoAllowlist[token] else { continue }
            let prefix = tokens[..<index]
            let hasGrammarPrefix = prefix.contains(where: grammarWords.contains)
            let followsBoundary = index + 1 < tokens.count && boundaryWords.contains(tokens[index + 1])
            guard hasGrammarPrefix || followsBoundary else { continue }
            return (token, source)
        }
        return nil
    }

    private func isExactLookupQuestion(_ question: String, surface: QuerySurface) -> Bool {
        let normalized = question.lowercased()
        let hasQuotedPhrase = normalized.contains("\"") || normalized.contains("“") || normalized.contains("”")
        let explicitLiteralMarkers = [
            "mention ", "mentions ", "mentioning ", "contains ", "containing ", "titled ", "called ", "named "
        ]
        if hasQuotedPhrase || explicitLiteralMarkers.contains(where: normalized.contains) { return true }
        if surface == .ask {
            // A note-specific find/any request remains a useful literal
            // lookup, while ordinary Ask commands such as "List everything
            // I need to do tomorrow" remain natural-language questions.
            return ["find a note", "which note", "any note", "any notes"].contains(where: normalized.contains)
        }
        return [
            "find ", "locate ", "which note", "list ", "any note", "any notes", "any mention",
            "do i have ", "are there "
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
            || !Set(Self.communicationSourceTypoAllowlist.keys).isDisjoint(with: Set(IdentityResolver.tokens(question)))
    }

    private func extractPersonPhrase(from question: String, sourceIntent: SourceIntentMatch?) -> String? {
        if let marked = extractMarkedPersonPhrase(from: question) {
            return marked
        }
        return extractKnownPersonBeforeSource(from: question, sourceIntent: sourceIntent)
    }

    /// Extracts a known contact from a deliberately elliptical continuation.
    /// Only the leading "and <person>" and "what about <person>" shapes are
    /// accepted, so an ordinary replacement question cannot accidentally
    /// inherit a prior topic.
    private func extractContinuationPersonPhrase(from question: String) -> String? {
        let tokens = IdentityResolver.tokens(question)
        let candidateTokens: ArraySlice<String>
        if tokens.first == "and" {
            candidateTokens = tokens.dropFirst()
        } else if tokens.count >= 2, tokens[0] == "what", tokens[1] == "about" {
            candidateTokens = tokens.dropFirst(2)
        } else {
            return nil
        }
        guard !candidateTokens.isEmpty else { return nil }
        return longestKnownIdentityPrefix(in: candidateTokens.joined(separator: " "))
    }

    private func extractMarkedPersonPhrase(from question: String) -> String? {
        let lowered = question.lowercased()
        if let range = lowered.range(of: "did ") {
            let tail = question[range.upperBound...]
            let stopWords = [
                " tell ", " told ", " say ", " said ", " mention ", " mentioned ",
                " ask ", " asked ", " last night", " yesterday", " today", "?"
            ]
            var candidate = String(tail)
            for stopWord in stopWords {
                if let stop = candidate.lowercased().range(of: stopWord) { candidate = String(candidate[..<stop.lowerBound]); break }
            }
            let name = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                // A natural question can continue past the contact with an
                // unlisted verb ("How much did Rafaela need?"). Prefer the
                // longest locally known identity prefix instead of treating
                // the rest of that clause as a person name.
                if let resolvedPrefix = longestKnownIdentityPrefix(in: name) {
                    return resolvedPrefix
                }
                guard !Self.isPronounLed(name) else { return nil }
                return name
            }
        }
        let markers = ["contact ", "with ", "from ", "for "]
        for marker in markers {
            guard let range = lowered.range(of: marker) else { continue }
            let tail = question[range.upperBound...]
            let candidate = tail.split(whereSeparator: { $0 == "?" || $0 == "." || $0 == "," }).first.map(String.init)
            if let candidate, !candidate.isEmpty {
                let cleaned = candidate.replacingOccurrences(of: "last night", with: "", options: .caseInsensitive)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // A source/date/topic phrase can follow a marked person
                // (for example, "from Rui this week"). Prefer the longest
                // locally resolvable prefix so the date/topic never prevents
                // exact identity resolution.
                if let resolvedPrefix = longestKnownIdentityPrefix(in: cleaned) {
                    return resolvedPrefix
                }
                guard !Self.isPronounLed(cleaned) else { continue }
                let nonPersonTokens: Set<String> = [
                    "today", "yesterday", "tomorrow", "this", "morning", "night", "week", "latest", "newest", "recent",
                    "most", "last", "upcoming", "next", "email", "emails", "mail", "message", "messages", "chat"
                ]
                guard !IdentityResolver.tokens(cleaned).allSatisfy(nonPersonTokens.contains) else { continue }
                return cleaned
            }
        }
        return nil
    }

    private static func isPronounLed(_ phrase: String) -> Bool {
        let pronouns: Set<String> = ["he", "she", "they", "him", "her", "them", "his", "hers", "their", "theirs", "i", "you"]
        return IdentityResolver.tokens(phrase).first.map(pronouns.contains) ?? false
    }

    private func longestKnownIdentityPrefix(in phrase: String) -> String? {
        let tokens = IdentityResolver.tokens(phrase)
        guard !tokens.isEmpty else { return nil }
        for length in stride(from: tokens.count, through: 1, by: -1) {
            let candidate = tokens.prefix(length).joined(separator: " ")
            if identityResolver.resolveWithConservativeFuzzy(candidate).isEmpty { continue }
            return candidate
        }
        return nil
    }

    /// Finds a contact in the person slot immediately before a source noun,
    /// optionally separated by a structural recency operator, such as
    /// "Cachinhos messages" or "Cachinhos latest messages". Exact identity
    /// resolution always wins; the fallback is a one-edit display-name/alias
    /// match and still flows through the normal ambiguity guard.
    private func extractKnownPersonBeforeSource(from question: String, sourceIntent: SourceIntentMatch?) -> String? {
        guard sourceIntent == nil || sourceIntent?.source == .mail || sourceIntent?.source == .messages else { return nil }
        let tokens = IdentityResolver.tokens(question)
        let communicationWords: Set<String>
        if let source = sourceIntent?.source {
            communicationWords = sourceWords(for: source)
        } else {
            communicationWords = sourceWords(for: .mail).union(sourceWords(for: .messages))
        }
        guard let sourceIndex = tokens.firstIndex(where: { token in
            communicationWords.contains(token)
        }), sourceIndex > 0 else { return nil }

        let recencyIndices = structuralRecencyOperatorIndices(
            in: tokens,
            sourceIndex: sourceIndex,
            source: sourceIntent?.source,
            count: tokens.compactMap(Int.init).first
        )
        let boundaryIndex = recencyIndices.min() ?? sourceIndex
        guard boundaryIndex > 0 else { return nil }

        var prefix = Array(tokens[..<boundaryIndex])
        // IdentityResolver.tokens splits an apostrophe into a standalone "s".
        // A trailing token is only discarded when there are other prefix
        // tokens, preserving ordinary one-token contact names.
        if prefix.count > 1, prefix.last == "s" { prefix.removeLast() }
        guard !prefix.isEmpty else { return nil }

        let grammarWords: Set<String> = [
            "summarize", "summary", "show", "list", "get", "give", "find", "what", "are", "the", "my", "our", "please",
            "me", "tell", "did", "can", "could", "would", "you", "do", "i"
        ]

        // Prefer the longest exact identity span, but allow a leading query
        // verb and a possessive suffix around it.
        for length in stride(from: prefix.count, through: 1, by: -1) {
            for start in 0...(prefix.count - length) {
                let end = start + length
                let before = prefix[..<start]
                let after = prefix[end...]
                guard before.allSatisfy({ grammarWords.contains($0) || Int($0) != nil }), after.allSatisfy({ $0 == "s" }) else { continue }
                let candidate = prefix[start..<end].joined(separator: " ")
                guard !candidate.isEmpty, !identityResolver.resolveWithConservativeFuzzy(candidate).isEmpty else { continue }
                return candidate
            }
        }
        return nil
    }

    fileprivate func acceptsStructuredTimeframe(_ intent: StructuredQueryIntent, referenceDate: Date) -> Bool {
        guard let phrase = intent.timeframePhrase, !phrase.isEmpty else { return true }
        return dateParser.parse(phrase, referenceDate: referenceDate) != nil
    }
}

/// Runs the optional model for natural Ask language whose meaning can benefit
/// from interpretation. Deterministic constraints remain authoritative and
/// Search-surface requests stay lexical without a model call.
struct HybridQueryPlanner: Sendable {
    static let defaultInterpretationTimeoutNanoseconds: UInt64 = 8_000_000_000

    let deterministic: QueryPlanner
    let interpreter: (any QueryIntentInterpreting)?
    let surface: QuerySurface
    let interpretationTimeoutNanoseconds: UInt64

    init(
        deterministic: QueryPlanner,
        interpreter: (any QueryIntentInterpreting)? = nil,
        surface: QuerySurface = .ask,
        interpretationTimeoutNanoseconds: UInt64 = Self.defaultInterpretationTimeoutNanoseconds
    ) {
        self.deterministic = deterministic
        self.interpreter = interpreter
        self.surface = surface
        self.interpretationTimeoutNanoseconds = interpretationTimeoutNanoseconds
    }

    init(
        planner: QueryPlanner,
        interpreter: (any QueryIntentInterpreting)? = nil,
        surface: QuerySurface = .ask,
        interpretationTimeoutNanoseconds: UInt64 = Self.defaultInterpretationTimeoutNanoseconds
    ) {
        self.init(
            deterministic: planner,
            interpreter: interpreter,
            surface: surface,
            interpretationTimeoutNanoseconds: interpretationTimeoutNanoseconds
        )
    }

    func plan(
        _ question: String,
        scope: SearchScope = SearchScope(),
        context: QueryPlan? = nil,
        referenceDate: Date? = nil,
        provider: AIProvider = .appleLocal
    ) async -> QueryPlan {
        let fallback = deterministic.plan(question, scope: scope, context: context, referenceDate: referenceDate, surface: surface)
        guard surface == .ask else { return fallback }
        // Keep the model available for unresolved natural-language meaning
        // even when local planning already found a person, date, or source.
        // The local plan remains authoritative when the model result merges.
        guard Self.shouldInterpret(fallback, surface: surface), let interpreter else { return fallback }
        guard let intent = await interpretWithinBudget(
            interpreter,
            question: String(question.prefix(600)),
            provider: provider,
            referenceDate: referenceDate ?? Date()
        ), intent.personPhraseIsCopiedFrom(question: question),
        deterministic.acceptsStructuredTimeframe(intent, referenceDate: referenceDate ?? Date()) else { return fallback }
        return deterministic.plan(
            question,
            scope: scope,
            context: context,
            referenceDate: referenceDate,
            structuredIntent: intent,
            surface: surface
        )
    }

    private func interpretWithinBudget(
        _ interpreter: any QueryIntentInterpreting,
        question: String,
        provider: AIProvider,
        referenceDate: Date
    ) async -> StructuredQueryIntent? {
        // Use an unstructured race so a non-cooperative test/model adapter
        // cannot hold the planner past its latency budget after timeout. The
        // losing task is cancelled, while the one-shot gate prevents a second
        // continuation resume when it eventually returns.
        await withCheckedContinuation { continuation in
            let gate = QueryIntentResultGate()
            let work = Task<StructuredQueryIntent?, Never> {
                try? await interpreter.interpret(question: question, provider: provider, referenceDate: referenceDate)
            }
            Task {
                await gate.setCancellation { work.cancel() }
                let result = await work.value
                await gate.finish(continuation, result: result)
            }
            Task {
                try? await Task.sleep(nanoseconds: interpretationTimeoutNanoseconds)
                await gate.finish(continuation, result: nil)
            }
        }
    }

    static func shouldInterpret(_ fallback: QueryPlan) -> Bool {
        shouldInterpret(fallback, surface: .ask)
    }

    private static func shouldInterpret(_ fallback: QueryPlan, surface: QuerySurface) -> Bool {
        guard surface == .ask else { return false }
        guard fallback.mode != .exactLookup else { return false }
        // The established deeper-answer path reuses the prior plan and
        // evidence window. It has no unresolved search intent of its own and
        // must not spend a second model call on the literal follow-up label.
        if fallback.continuesConversation && QueryPlanner.looksLikeFollowUp(fallback.originalQuestion) {
            return false
        }
        // Local date/person/source/order/count constraints remain authoritative
        // during merge, but an ordering or count does not make a request
        // literal. The model can still interpret the natural question around
        // those current-turn operators.
        return true
    }
}

private actor QueryIntentResultGate {
    private var completed = false
    private var cancelWork: (@Sendable () -> Void)?

    func setCancellation(_ cancellation: @escaping @Sendable () -> Void) {
        if completed {
            cancellation()
        } else {
            cancelWork = cancellation
        }
    }

    func finish(_ continuation: CheckedContinuation<StructuredQueryIntent?, Never>, result: StructuredQueryIntent?) {
        guard !completed else { return }
        completed = true
        cancelWork?()
        continuation.resume(returning: result)
    }
}
