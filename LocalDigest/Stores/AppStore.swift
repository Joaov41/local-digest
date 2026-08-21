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

    let indexCoordinator: IndexCoordinator
    let modelService: FoundationModelService?
    private var planner = QueryPlanner()
    private var conversationPlan: QueryPlan?
    private let savedAnswersKey = "savedAnswers"
    private let logger = Logger(subsystem: "com.web.me.LocalDigest", category: "models")

    init(indexCoordinator: IndexCoordinator = IndexCoordinator()) {
        self.indexCoordinator = indexCoordinator
        if let data = UserDefaults.standard.data(forKey: savedAnswersKey),
           let saved = try? JSONDecoder().decode([SavedAnswer].self, from: data) {
            savedAnswers = saved
        }
        if #available(macOS 26.0, *) { modelService = FoundationModelService() } else { modelService = nil }
    }

    func refresh() async {
        sourceStatuses = await indexCoordinator.statuses()
        do { people = try await indexCoordinator.people() } catch { people = [] }
        do {
            planner = QueryPlanner(identityResolver: IdentityResolver(identities: try await indexCoordinator.identities()))
        } catch {
            planner = QueryPlanner()
        }
        await refreshModelAvailability()
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
        sourceStatuses = await indexCoordinator.indexAll(mode: mode) { [weak self] source, count, total in
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
        }
        do { people = try await indexCoordinator.people() } catch { }
        do {
            planner = QueryPlanner(identityResolver: IdentityResolver(identities: try await indexCoordinator.identities()))
        } catch { }
    }

    func performSearch() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { hits = []; return }
        isSearching = true
        errorMessage = nil
        defer { isSearching = false }
        do {
            let plan = planner.plan(query)
            guard plan.ambiguity.isEmpty else {
                errorMessage = "More than one contact matches: \(plan.ambiguity.joined(separator: ", ")). Add a surname or choose the person first."
                hits = []
                return
            }
            hits = try await indexCoordinator.search(plan: plan)
        }
        catch { errorMessage = error.localizedDescription }
    }

    func ask() async {
        let query = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        isAnswering = true
        defer { isAnswering = false }
        errorMessage = nil
        answerText = ""
        answer = nil
        selectedHit = nil
        let requestProvider = provider
        let requestDate = Date()
        do {
            let plan = planner.plan(query, context: conversationPlan, referenceDate: requestDate)
            guard plan.ambiguity.isEmpty else {
                throw QueryPlanningError.ambiguousContacts(plan.ambiguity)
            }
            hits = try await indexCoordinator.search(plan: plan)
            if plan.mode == .exactLookup, requestProvider == .appleLocal {
                answerText = groundedExactAnswer(for: plan, hits: hits)
            } else {
                guard let modelService else { throw FoundationModelError.unavailable("Apple Foundation Models require macOS 26 or later.") }
                for try await chunk in await modelService.stream(question: query, evidence: hits, provider: requestProvider, intent: plan.intent, referenceDate: requestDate) {
                    answerText = PromptBuilder.sanitizedAnswer(chunk, referenceDate: requestDate)
                }
                if answerText.isEmpty || deniesExactEvidence(answerText) {
                    answerText = plan.mode == .exactLookup
                        ? groundedExactAnswer(for: plan, hits: hits)
                        : groundedEvidenceSummary(hits: hits)
                }
            }
            let citations = hits.prefix(24).map(\.citation)
            answer = Answer(text: answerText, citations: citations, provider: requestProvider)
            conversationPlan = plan
            conversationTurns.append(ConversationTurn(question: query, answer: answerText, citations: citations, provider: requestProvider))
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
        let normalized = answer.lowercased()
        return normalized.contains("no matching") || normalized.contains("not found") || normalized.contains("no evidence") || normalized.contains("couldn't find")
    }

    private func groundedEvidenceSummary(hits: [SearchHit]) -> String {
        guard !hits.isEmpty else { return "The indexed evidence did not contain a matching record." }
        let sourceCounts = Dictionary(grouping: hits, by: { $0.record.source.title })
            .map { "\($0.value.count) \($0.key) record\($0.value.count == 1 ? "" : "s")" }
            .sorted()
            .joined(separator: ", ")
        return "The indexed evidence contains " + sourceCounts + "."
    }

    func saveCurrentAnswer() {
        guard !answerText.isEmpty, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let saved = SavedAnswer(id: UUID(), question: question, text: answerText, provider: provider, savedAt: Date())
        savedAnswers.insert(saved, at: 0)
        persistSavedAnswers()
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
