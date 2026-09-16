import Combine
import Foundation
import OSLog

@MainActor
final class AppStore: ObservableObject {
    @Published var section: AppSection = .ask
    @Published var provider: AIProvider = .appleLocal
    @Published var question = ""
    @Published var searchText = ""
    @Published var hits: [SearchHit] = []
    @Published var answer: Answer?
    @Published var answerText = ""
    @Published var conversationTurns: [ConversationTurn] = []
    @Published var isSearching = false
    @Published var isAnswering = false
    /// A refresh is deliberately a background activity. Existing search,
    /// answers, navigation, and saved content remain usable throughout it.
    @Published var isIndexing = false
    @Published var refreshMode: IndexRefreshMode?
    @Published var refreshStartedAt: Date?
    @Published var errorMessage: String?
    @Published var selectedHit: SearchHit?
    @Published var savedAnswers: [SavedAnswer] = []
    @Published var sourceStatuses: [SourceStatus] = SourceKind.allCases.map { SourceStatus(source: $0, permission: .notDetermined, indexedCount: 0, isIndexing: false, message: nil) }
    @Published var people: [String] = []
    @Published var modelAvailability: [AIProvider: ModelAvailability] = [:]
    @Published private(set) var accessRequests: Set<SourceKind> = []
    @Published var pendingDraft: ReplyDraft?
    @Published var isDrafting = false
    @Published var draftErrorMessage: String?
    @Published var autoSyncInterval: AutoSyncInterval

    let indexCoordinator: IndexCoordinator
    let modelService: FoundationModelService?
    let replyDispatcher = ReplyDispatcher()
    private let intentInterpreter: (any QueryIntentInterpreting)?
    private let answerStreamer: (any AnswerStreaming)?
    private var planner = QueryPlanner()
    private var plannerReady = false
    private var plannerLoadTask: Task<[ContactIdentity]?, Never>?
    private var conversationPlan: QueryPlan?
    // Cumulative retrieved evidence is separate from the currently displayed
    // answer window. It lets later turns refer to an earlier turn without
    // allowing an unbounded transcript/evidence prompt.
    private var conversationEvidence: [SearchHit] = []
    private var isDeeperFollowUp = false
    private var lastSubmittedQuestion: String?
    private var autoSyncTask: Task<Void, Never>?
    private let savedAnswersKey = "savedAnswers"
    private static let autoSyncKey = "LocalDigest.autoSyncMinutes"
    private let logger = Logger(subsystem: "com.web.me.LocalDigest", category: "models")

    init(
        indexCoordinator: IndexCoordinator = IndexCoordinator(),
        intentInterpreter: (any QueryIntentInterpreting)? = nil,
        answerStreamer: (any AnswerStreaming)? = nil
    ) {
        self.indexCoordinator = indexCoordinator
        if let data = UserDefaults.standard.data(forKey: savedAnswersKey),
           let saved = try? JSONDecoder().decode([SavedAnswer].self, from: data) {
            savedAnswers = saved
        }
        let storedMinutes = UserDefaults.standard.object(forKey: Self.autoSyncKey) as? Int
        self.autoSyncInterval = AutoSyncInterval(minutes: storedMinutes ?? AutoSyncInterval.fifteen.rawValue)
        if #available(macOS 26.0, *) {
            let service = FoundationModelService()
            modelService = service
            self.intentInterpreter = intentInterpreter ?? service
            self.answerStreamer = answerStreamer ?? service
        } else {
            modelService = nil
            self.intentInterpreter = intentInterpreter
            self.answerStreamer = answerStreamer
        }
    }

    convenience init(
        indexCoordinator: IndexCoordinator,
        interpreter: (any QueryIntentInterpreting),
        answerStreamer: (any AnswerStreaming)? = nil
    ) {
        self.init(indexCoordinator: indexCoordinator, intentInterpreter: interpreter, answerStreamer: answerStreamer)
    }

    convenience init(
        indexCoordinator: IndexCoordinator,
        queryIntentInterpreter: (any QueryIntentInterpreting),
        answerStreamer: (any AnswerStreaming)? = nil
    ) {
        self.init(indexCoordinator: indexCoordinator, intentInterpreter: queryIntentInterpreter, answerStreamer: answerStreamer)
    }

    /// Syncs incrementally shortly after launch and then on the configured
    /// cadence. The coordinator coalesces overlapping refreshes and skips
    /// unauthorized sources, so a tick is cheap when nothing changed.
    func startAutoSync() {
        autoSyncTask?.cancel()
        autoSyncTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { return }
            await self.indexSources()
            while !Task.isCancelled {
                let seconds = self.autoSyncInterval.seconds
                guard seconds > 0 else { return }
                try? await Task.sleep(for: .seconds(seconds))
                if Task.isCancelled { return }
                await self.indexSources()
            }
        }
    }

    func setAutoSync(_ interval: AutoSyncInterval) {
        autoSyncInterval = interval
        UserDefaults.standard.set(interval.rawValue, forKey: Self.autoSyncKey)
        startAutoSync()
    }

    func refresh() async {
        sourceStatuses = await indexCoordinator.statuses()
        do { people = try await indexCoordinator.people() } catch { people = [] }
        await ensurePlannerReady(force: true)
        await refreshModelAvailability()
    }

    /// Ask can be submitted while the initial background refresh is still
    /// loading source metadata. Resolve indexed identities on demand so a
    /// contact-name question never races the empty startup planner.
    private func ensurePlannerReady(force: Bool = false) async {
        if plannerReady && !force { return }
        if let plannerLoadTask {
            if let identities = await plannerLoadTask.value {
                planner = QueryPlanner(identityResolver: IdentityResolver(identities: identities))
                plannerReady = true
            }
            return
        }
        let coordinator = indexCoordinator
        let task = Task<[ContactIdentity]?, Never> {
            try? await coordinator.identities()
        }
        plannerLoadTask = task
        let identities = await task.value
        plannerLoadTask = nil
        guard let identities else { return }
        planner = QueryPlanner(identityResolver: IdentityResolver(identities: identities))
        plannerReady = true
    }

    func refreshModelAvailability() async {
        guard let modelService else { return }
        for provider in AIProvider.allCases {
            let availability = await modelService.availability(for: provider)
            modelAvailability[provider] = availability
            logger.notice("\(provider.title, privacy: .public) availability: \(availability.isAvailable, privacy: .public); \(availability.detail, privacy: .public)")
        }
    }

    func requestAccess(for source: SourceKind) async {
        guard !accessRequests.contains(source) else { return }
        accessRequests.insert(source)
        defer { accessRequests.remove(source) }
        if let updated = await indexCoordinator.requestAccess(for: source), let index = sourceStatuses.firstIndex(where: { $0.source == source }) {
            sourceStatuses[index] = updated
        }
    }

    func isRequestingAccess(for source: SourceKind) -> Bool {
        accessRequests.contains(source)
    }

    func setProvider(_ newProvider: AIProvider) {
        guard !isAnswering else { return }
        if newProvider == .privateCloud {
            guard #available(macOS 27.0, *) else {
                provider = .appleLocal
                return
            }
        }
        provider = newProvider
    }

    func startNewConversation() async {
        guard !isAnswering else { return }
        question = ""
        conversationTurns.removeAll()
        conversationPlan = nil
        conversationEvidence.removeAll()
        isDeeperFollowUp = false
        lastSubmittedQuestion = nil
        hits = []
        answer = nil
        answerText = ""
        selectedHit = nil
        errorMessage = nil
        if let modelService { await modelService.resetSessions() }
    }

    func indexSources() async {
        await runIndex(mode: .incremental)
    }

    func rebuildIndex() async {
        await runIndex(mode: .fullRebuild)
    }

    private func runIndex(mode: IndexRefreshMode) async {
        guard !isIndexing else { return }
        isIndexing = true
        refreshMode = mode
        refreshStartedAt = Date()
        errorMessage = nil
        defer {
            isIndexing = false
            refreshMode = nil
            refreshStartedAt = nil
        }
        sourceStatuses = await indexCoordinator.indexAll(mode: mode, progress: { [weak self] source, count, total in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let index = self.sourceStatuses.firstIndex(where: { $0.source == source }) {
                    var status = self.sourceStatuses[index]
                    status.isIndexing = total == -1 || (count >= 0 && count != total)
                    // A progress callback is not a commit. Keep the previous
                    // count visible until this source's replacement succeeds.
                    if total >= 0, count >= 0 { status.indexedCount = count }
                    self.sourceStatuses[index] = status
                }
            }
        }, detail: { [weak self] source, message in
            Task { @MainActor [weak self] in
                guard let self, let index = self.sourceStatuses.firstIndex(where: { $0.source == source }) else { return }
                self.sourceStatuses[index].message = message
            }
        })
        do { people = try await indexCoordinator.people() } catch { }
        await ensurePlannerReady(force: true)
    }

    func performSearch() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isSearching else { if query.isEmpty { hits = [] }; return }
        isSearching = true
        defer { isSearching = false }
        await ensurePlannerReady()
        errorMessage = nil
        do {
            let plan = await HybridQueryPlanner(deterministic: planner, interpreter: intentInterpreter)
                .plan(query, provider: provider)
            guard plan.ambiguity.isEmpty else {
                errorMessage = "More than one contact matches: \(plan.ambiguity.joined(separator: ", ")). Add a surname or choose the person first."
                hits = []
                return
            }
            hits = try await indexCoordinator.search(plan: plan)
        }
        catch { errorMessage = error.localizedDescription }
    }

    /// Clears only the toolbar search state and displayed search results.
    /// Ask/conversation state, source status, and the index remain untouched.
    func clearSearch() {
        searchText = ""
        hits = []
        if section == .search { errorMessage = nil }
    }

    func ask() async {
        let query = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isAnswering, !isDrafting else { return }
        if let intent = ReplyIntentDetector.parse(query) {
            await beginReplyDraft(intent: intent, query: query)
            return
        }
        // Claim the turn before any planner/index await so repeated submits
        // cannot start duplicate intent or answer-model requests.
        isAnswering = true
        defer { isAnswering = false }
        await ensurePlannerReady()
        let activeConversation = conversationPlan != nil
        let deeperRequest = isDeeperFollowUp
        let previousAnswer = activeConversation ? answerText : nil
        let previousEvidence = activeConversation ? conversationEvidence : []
        let previousEvidenceIDs = deeperRequest ? Set(previousEvidence.map(\.id)) : []
        // This is a one-shot mode. Clear it before any await so an error,
        // cancellation, or the next concrete question cannot inherit it.
        isDeeperFollowUp = false
        errorMessage = nil
        answerText = ""
        answer = nil
        selectedHit = nil
        let requestProvider = provider
        let requestDate = Date()
        do {
            let plan = await HybridQueryPlanner(deterministic: planner, interpreter: intentInterpreter)
                .plan(query, context: conversationPlan, referenceDate: requestDate, provider: requestProvider)
            guard plan.ambiguity.isEmpty else {
                throw QueryPlanningError.ambiguousContacts(plan.ambiguity)
            }
            let retrievalLimit = deeperRequest ? 120 : (plan.requestedResultCount ?? 60)
            let retrieved = try await indexCoordinator.search(plan: plan, limit: retrievalLimit)
            if deeperRequest {
                hits = Self.selectDeeperEvidence(retrieved: retrieved, priorIDs: previousEvidenceIDs, priorEvidence: previousEvidence)
            } else if plan.ordering != .relevance {
                hits = Array(retrieved.prefix(plan.requestedResultCount ?? retrieved.count))
            } else if activeConversation {
                hits = Self.mergeConversationEvidence(retrieved: retrieved, prior: previousEvidence, constraints: plan.constraints)
            } else {
                hits = retrieved
            }
            // An empty retrieval is a grounded result in its own right. Do
            // not invoke or stream an answer model without source evidence.
            if hits.isEmpty {
                answerText = plan.mode == .exactLookup
                    ? groundedExactAnswer(for: plan, hits: hits)
                    : groundedEvidenceSummary(hits: hits)
            } else if plan.mode == .exactLookup, requestProvider == .appleLocal {
                answerText = groundedExactAnswer(for: plan, hits: hits)
            } else {
                guard let answerStreamer else { throw FoundationModelError.unavailable("Apple Foundation Models require macOS 26 or later.") }
                for try await chunk in await answerStreamer.stream(question: query, evidence: hits, provider: requestProvider, intent: plan.intent, referenceDate: requestDate, previousAnswer: previousAnswer, requireNewDetails: deeperRequest, evidenceOrdering: plan.ordering) {
                    answerText = PromptBuilder.sanitizedAnswer(chunk, referenceDate: requestDate)
                }
                // Sanitize the completed stream once more before it can reach
                // Answer/citations or any later saved state.
                answerText = PromptBuilder.sanitizedAnswer(answerText, referenceDate: requestDate)
                if answerText.isEmpty || deniesExactEvidence(answerText) {
                    answerText = plan.mode == .exactLookup
                        ? groundedExactAnswer(for: plan, hits: hits)
                        : groundedEvidenceSummary(hits: hits)
                }
            }
            let citations = hits.prefix(24).map(\.citation)
            answer = Answer(text: answerText, citations: citations, provider: requestProvider)
            conversationPlan = plan
            conversationEvidence = Self.mergeConversationEvidence(
                retrieved: hits,
                prior: previousEvidence,
                constraints: plan.constraints,
                limit: 96
            )
            conversationTurns.append(ConversationTurn(question: query, answer: answerText, citations: citations, provider: requestProvider))
            lastSubmittedQuestion = query
            question = ""
        } catch { errorMessage = error.localizedDescription }
    }

    private func groundedExactAnswer(for plan: QueryPlan, hits: [SearchHit]) -> String {
        guard !hits.isEmpty else {
            let source = plan.constraints.sources.first?.title.lowercased() ?? "source"
            return "I couldn't find a matching " + source + " record in the indexed evidence."
        }
        let source = plan.constraints.sources.first?.title.lowercased() ?? "source"
        if let title = hits.first(where: { hit in
            plan.keywords.contains { hit.record.title.localizedCaseInsensitiveCompare($0) == .orderedSame }
        })?.record.title {
            return "Found the " + source + " “" + title + "”."
        }
        return "Found " + String(hits.count) + " matching " + source + " record" + (hits.count == 1 ? "" : "s") + "."
    }

    private func deniesExactEvidence(_ answer: String) -> Bool {
        PromptBuilder.hasDenialAtSentenceStart(answer)
    }

    private func groundedEvidenceSummary(hits: [SearchHit]) -> String {
        guard !hits.isEmpty else { return "The indexed evidence did not contain a matching record." }
        let sourceCounts = Dictionary(grouping: hits, by: { $0.record.source.title })
            .map { "\($0.value.count) \($0.key) record\($0.value.count == 1 ? "" : "s")" }
            .sorted()
            .joined(separator: ", ")
        return "The indexed evidence contains " + sourceCounts + "."
    }

    /// Runs a follow-up question that continues the current conversation.
    func askFollowUp(_ text: String) async {
        guard !isAnswering, !isDrafting else { return }
        question = text
        await ask()
    }

    /// Public convenience for the UI while retaining the established
    /// follow-up planning and context-inheritance path.
    func goDeeper() async {
        guard canGoDeeper else { return }
        isDeeperFollowUp = true
        await askFollowUp("Go deeper on this")
    }

    var canGoDeeper: Bool {
        !isAnswering && !isDrafting && answer != nil && !answerText.isEmpty && !hits.isEmpty
    }

    var isConversationActive: Bool {
        !conversationTurns.isEmpty || conversationPlan != nil
    }

    var composerTitle: String {
        isConversationActive ? "Ask a follow-up" : "Ask Local Digest"
    }

    var composerPlaceholder: String {
        isConversationActive ? "Ask another question about this answer…" : "What did Rui tell me last night? Summarize our conversation."
    }

    var composerSubmitTitle: String {
        isConversationActive ? "Follow up" : "Ask"
    }

    var questionForSaving: String? {
        if let lastSubmittedQuestion { return lastSubmittedQuestion }
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var isDeeperFollowUpPending: Bool { isDeeperFollowUp }

    var conversationEvidenceCount: Int { conversationEvidence.count }

    nonisolated static func selectDeeperEvidence(retrieved: [SearchHit], priorIDs: Set<String>, priorEvidence: [SearchHit] = [], limit: Int = 24) -> [SearchHit] {
        let unseen = retrieved.filter { !priorIDs.contains($0.id) }
        var prior: [SearchHit] = []
        var seen = Set<String>()
        for hit in retrieved + priorEvidence where priorIDs.contains(hit.id) {
            if seen.insert(hit.id).inserted { prior.append(hit) }
            if prior.count == 4 { break }
        }
        let safeLimit = max(1, limit)
        let priorWindow = Array(prior.prefix(min(prior.count, min(4, safeLimit))))
        let unseenWindow = Array(unseen.prefix(max(0, safeLimit - priorWindow.count)))
        return unseenWindow + priorWindow
    }

    nonisolated static func mergeConversationEvidence(retrieved: [SearchHit], prior: [SearchHit], constraints: SearchConstraints, limit: Int = 24) -> [SearchHit] {
        var combined: [SearchHit] = []
        var seen = Set<String>()
        for hit in (retrieved + prior) where evidenceMatches(hit, constraints: constraints) {
            if seen.insert(hit.id).inserted { combined.append(hit) }
            if combined.count == max(1, limit) { break }
        }
        return combined
    }

    private nonisolated static func evidenceMatches(_ hit: SearchHit, constraints: SearchConstraints) -> Bool {
        let record = hit.record
        guard constraints.sources.contains(record.source) else { return false }
        if let start = constraints.startDate, record.timestamp < start { return false }
        if let end = constraints.endDate, record.timestamp >= end { return false }
        guard !constraints.personTerms.isEmpty else { return true }
        let fields = [record.author].compactMap { $0 } + record.participants
        return constraints.personTerms.contains { term in
            fields.contains { IdentityResolver.matchesSearchTerm(term, against: $0) }
        }
    }

    func saveCurrentAnswer() {
        guard !answerText.isEmpty, let questionForSaving else { return }
        let saved = SavedAnswer(id: UUID(), question: questionForSaving, text: answerText, provider: provider, savedAt: Date())
        savedAnswers.insert(saved, at: 0)
        persistSavedAnswers()
    }

    // MARK: Reply drafting

    /// Entry point for "Draft reply" actions on a specific mail or message hit.
    func requestReplyDraft(for hit: SearchHit) async {
        guard hit.record.source == .mail || hit.record.source == .messages else { return }
        await beginReplyDraft(intent: ReplyIntent(recipientPhrase: nil, instruction: nil, preferredChannel: nil), query: "", targetHit: hit)
    }

    private func beginReplyDraft(intent: ReplyIntent, query: String, targetHit: SearchHit? = nil) async {
        guard !isDrafting, !isAnswering else { return }
        isDrafting = true
        let draftProvider = provider
        draftErrorMessage = nil
        defer { isDrafting = false }
        errorMessage = nil

        guard let modelService else {
            errorMessage = FoundationModelError.unavailable("Apple Foundation Models require macOS 26 or later.").localizedDescription
            return
        }

        do {
            var conversationHits: [SearchHit]
            var candidateHits: [SearchHit]
            var personTerms: [String] = []
            if let targetHit {
                candidateHits = [targetHit]
                if let threadID = targetHit.record.threadID {
                    conversationHits = try await indexCoordinator.conversation(threadID: threadID)
                } else {
                    conversationHits = [targetHit]
                }
            } else {
                let requestDate = Date()
                let plan = planner.plan(query, context: conversationPlan, referenceDate: requestDate)
                guard plan.ambiguity.isEmpty else {
                    throw QueryPlanningError.ambiguousContacts(plan.ambiguity)
                }
                candidateHits = try await indexCoordinator.search(plan: plan)
                conversationHits = candidateHits
                personTerms = plan.constraints.personTerms
            }

            let channel = resolveChannel(for: intent, hits: candidateHits)
            let communication = candidateHits.filter { $0.record.source == channel.sourceKind }
            guard let target = Self.replyTarget(in: communication.isEmpty ? candidateHits : communication, personTerms: personTerms) else {
                throw ReplySendError.unavailable(channel, "No incoming message or email was found to reply to.")
            }
            if !conversationHits.contains(where: { $0.id == target.id }) {
                conversationHits.append(target)
            }

            let recipient = try await resolveRecipient(channel: channel, target: target.record)
            let chronological = conversationHits.sorted { $0.record.timestamp < $1.record.timestamp }.map(\.record)

            let generated = try await modelService.draftReply(
                instruction: intent.instruction ?? "",
                target: target.record,
                conversation: chronological,
                provider: draftProvider
            )
            pendingDraft = ReplyDraft(
                channel: channel,
                recipient: recipient.address,
                recipientDisplayName: recipient.displayName,
                subject: generated.subject,
                body: generated.body,
                sourceRecordID: target.record.id,
                evidence: Array(candidateHits.prefix(8).map(\.citation))
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func resolveChannel(for intent: ReplyIntent, hits: [SearchHit]) -> ReplyChannel {
        if let preferred = intent.preferredChannel { return preferred }
        let sources = Set(hits.map(\.record.source))
        if sources == [.mail] { return .mail }
        if sources == [.messages] { return .messages }
        return .messages
    }

    /// The reply goes to the most recent record authored by someone other
    /// than the user, so a thread the user last wrote in still targets the
    /// other participant.
    private static func replyTarget(in hits: [SearchHit], personTerms: [String]) -> SearchHit? {
        ReplyTargetSelector.select(in: hits, personTerms: personTerms)
    }

    private func resolveRecipient(channel: ReplyChannel, target: IndexedRecord) async throws -> (address: String, displayName: String?) {
        let identities = (try? await indexCoordinator.identities()) ?? []
        let searchableTarget = target.searchableText
        let matchedIdentity = identities.first { identity in
            let terms = ([identity.displayName].compactMap { $0 }) + identity.aliases + identity.handles
            return terms.contains { term in !term.isEmpty && searchableTarget.localizedCaseInsensitiveContains(term) }
        }

        switch channel {
        case .mail:
            let candidates = ([matchedIdentity?.handles ?? [], target.participants, [target.author].compactMap { $0 }]).flatMap { $0 }
            if let address = candidates.lazy.compactMap(EmailAddressExtractor.extract(from:)).first {
                let displayName = matchedIdentity?.displayName ?? EmailAddressExtractor.displayName(fromSender: target.author)
                return (address, displayName)
            }
            throw ReplySendError.invalidRecipient(.mail)
        case .messages:
            if let threadID = target.threadID, threadID.contains(";") {
                return (threadID, matchedIdentity?.displayName ?? target.author)
            }
            let candidates = ([matchedIdentity?.handles ?? [], target.participants, [target.author].compactMap { $0 }]).flatMap { $0 }
            if let handle = candidates.first(where: { Self.looksLikeMessageHandle($0) }) {
                return (handle, matchedIdentity?.displayName ?? target.author)
            }
            throw ReplySendError.invalidRecipient(.messages)
        }
    }

    private static func looksLikeMessageHandle(_ value: String) -> Bool {
        if value.range(of: #"^(imessage|sms);.+"#, options: .regularExpression) != nil { return true }
        let digits = value.filter(\.isNumber)
        return digits.count >= 7 && value.rangeOfCharacter(from: .letters) == nil
    }

    /// Sends only after the user reviewed and explicitly confirmed the draft.
    func confirmSend(draft: ReplyDraft) async {
        draftErrorMessage = nil
        do {
            try await replyDispatcher.send(draft)
            pendingDraft = nil
            let turn = ConversationTurn(
                question: "Reply to \(draft.recipientDisplayName ?? draft.recipient)",
                answer: "Sent via \(draft.channel.title): \(draft.body)",
                citations: draft.evidence,
                provider: provider
            )
            conversationTurns.append(turn)
        } catch {
            draftErrorMessage = error.localizedDescription
        }
    }

    func cancelDraft() {
        pendingDraft = nil
        draftErrorMessage = nil
    }

    func deleteSavedAnswer(_ saved: SavedAnswer) {
        savedAnswers.removeAll { $0.id == saved.id }
        persistSavedAnswers()
    }

    private func persistSavedAnswers() {
        if let data = try? JSONEncoder().encode(savedAnswers) {
            UserDefaults.standard.set(data, forKey: savedAnswersKey)
        }
    }
}

enum QueryPlanningError: LocalizedError {
    case ambiguousContacts([String])

    var errorDescription: String? {
        switch self {
        case .ambiguousContacts(let names):
            "More than one contact matches: \(names.joined(separator: ", ")). Add a surname or choose the person first."
        }
    }
}
