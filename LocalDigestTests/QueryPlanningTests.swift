import XCTest
import Contacts
@testable import LocalDigest

final class QueryPlanningTests: XCTestCase {
    func testContactDisplayNameUsesOnlyExplicitNameComponents() {
        let contact = CNMutableContact()
        contact.givenName = "Rui"
        contact.middleName = "Miguel"
        contact.familyName = "Almeida"
        XCTAssertEqual(ContactsSourceAdapter.displayName(for: contact), "Rui Miguel Almeida")
    }

    func testContactDisplayNameFallsBackWithoutCallingContactFormatter() {
        let contact = CNMutableContact()
        contact.organizationName = "Example Shipping"
        XCTAssertEqual(ContactsSourceAdapter.displayName(for: contact), "Example Shipping")
    }

    func testCalendarHistoryIsPartitionedIntoEventKitSafeWindows() {
        let ranges = CalendarSourceAdapter.historyRanges()
        XCTAssertFalse(ranges.isEmpty)
        XCTAssertTrue(ranges.allSatisfy { $0.duration <= 4 * 366 * 24 * 60 * 60 })
        XCTAssertEqual(ranges.dropFirst().map(\.start), ranges.dropLast().map(\.end))
    }

    func testLastNightSpansPreviousEveningAndCurrentMorning() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = ISO8601DateFormatter().date(from: "2026-08-20T10:00:00Z")!
        let parser = DatePhraseParser(calendar: calendar, now: { now })
        let result = parser.parse("What did Rui tell me last night?")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.start, ISO8601DateFormatter().date(from: "2026-08-19T18:00:00Z"))
        XCTAssertEqual(result?.end, ISO8601DateFormatter().date(from: "2026-08-20T05:00:00Z"))
    }

    func testTomorrowUsesLocalStartOfDayAcrossTimezoneBoundary() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        let reference = ISO8601DateFormatter().date(from: "2026-08-21T23:30:00Z")!
        let parser = DatePhraseParser(calendar: calendar, now: { reference })
        let result = parser.parse("what is on my calendar tomorrow?")!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: reference))!
        XCTAssertEqual(result.start, tomorrow)
        XCTAssertEqual(result.end, calendar.date(byAdding: .day, value: 1, to: tomorrow))
    }

    func testExplicitCalendarIntentOverridesPriorMessagesConversation() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let reference = ISO8601DateFormatter().date(from: "2026-08-21T10:00:00Z")!
        let planner = QueryPlanner(dateParser: DatePhraseParser(calendar: calendar, now: { reference }))
        let prior = QueryPlan(
            originalQuestion: "What did Rui say last night?",
            keywords: ["shipment"],
            constraints: SearchConstraints(person: "Rui Almeida", personTerms: ["rui@example.test"], startDate: reference.addingTimeInterval(-86_400), endDate: reference, sources: [.messages]),
            needsConversationExpansion: true,
            ambiguity: []
        )

        let plan = planner.plan("what is on my calendar for tomorrow?", context: prior)

        XCTAssertEqual(plan.constraints.sources, [.calendar])
        XCTAssertNil(plan.constraints.person)
        XCTAssertTrue(plan.constraints.personTerms.isEmpty)
        XCTAssertTrue(plan.keywords.isEmpty)
        XCTAssertFalse(plan.needsConversationExpansion)
        XCTAssertEqual(plan.mode, .questionAnswer)
        XCTAssertEqual(plan.intent, .explicitSource(.calendar))
        XCTAssertEqual(plan.constraints.startDate, calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: reference)))
    }

    func testSourceRoutingMatrixAndEmailCalendarTopic() {
        let planner = QueryPlanner()
        let cases: [(String, SourceKind)] = [
            ("what is on my calendar tomorrow?", .calendar),
            ("find an email about the shipment", .mail),
            ("show my messages about the shipment", .messages),
            ("find a note with rss on it", .notes),
            ("list my reminders for tomorrow", .reminders),
            ("find Rui's contact details", .contacts)
        ]
        for (question, source) in cases {
            let plan = planner.plan(question)
            XCTAssertEqual(plan.constraints.sources, [source], question)
            XCTAssertEqual(plan.intent, .explicitSource(source), question)
        }

        let mailPlan = planner.plan("email about the calendar")
        XCTAssertEqual(mailPlan.constraints.sources, [.mail])
        XCTAssertEqual(mailPlan.keywords, ["calendar"])
    }

    func testNotesHTMLIsConvertedAndUnknownDatesAreNotRendered() {
        XCTAssertEqual(NotesSourceAdapter.htmlToPlainText("<div><h1>Rss</h1></div><div>Read &amp; review</div>"), "Rss\nRead & review")
        let unknown = IndexedRecord(id: "note-unknown", source: .notes, title: "Rss", body: "rss", author: nil, participants: [], timestamp: .distantPast, url: nil, threadID: nil)
        let hit = SearchHit(record: unknown, score: 1)
        let prompt = PromptBuilder.makePrompt(question: "find a note with rss", evidence: [hit])
        XCTAssertFalse(prompt.contains("Dec 31, 1"))
        XCTAssertFalse(prompt.contains("date="))
    }

    func testExactRSSLookupFiltersDistractorsToNotesAndRanksTitle() async throws {
        let databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("local-digest-rss-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-shm")
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-wal")
        }
        let index = SQLiteIndex(databaseURL: databaseURL)
        try await index.upsert([
            IndexedRecord(id: "note-rss", source: .notes, title: "Rss", body: "Read the feed", author: nil, participants: [], timestamp: Date(), url: nil, threadID: nil),
            IndexedRecord(id: "note-unrelated", source: .notes, title: "Antibiotics", body: "Medication", author: nil, participants: [], timestamp: Date(), url: nil, threadID: nil),
            IndexedRecord(id: "message-rss", source: .messages, title: "Me", body: "RSS in a message", author: "Me", participants: [], timestamp: Date(), url: nil, threadID: "chat")
        ])
        let plan = QueryPlanner().plan("find a note with rss on it")
        let hits = try await index.search(plan: plan, limit: 20)
        XCTAssertEqual(plan.mode, .exactLookup)
        XCTAssertEqual(plan.keywords, ["rss"])
        XCTAssertEqual(hits.map(\.record.id), ["note-rss"])
        XCTAssertTrue(hits.allSatisfy { $0.record.source == .notes })
    }

    func testRSSLookupIntentDistinguishesMentionsTopicsAndTitles() async throws {
        let databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("local-digest-rss-intents-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-shm")
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-wal")
        }
        let index = SQLiteIndex(databaseURL: databaseURL)
        try await index.upsert([
            IndexedRecord(id: "note-title-rss", source: .notes, title: "Rss", body: "Read the feed", author: nil, participants: [], timestamp: Date(), url: nil, threadID: nil),
            IndexedRecord(id: "note-title-RSS", source: .notes, title: "RSS", body: "Another feed", author: nil, participants: [], timestamp: Date(), url: nil, threadID: nil),
            IndexedRecord(id: "note-browser", source: .notes, title: "Our browser-use CLI", body: "RSS post and comments", author: nil, participants: [], timestamp: Date(), url: nil, threadID: nil),
            IndexedRecord(id: "note-contract", source: .notes, title: "CONTRATO MSC", body: "An incidental rss mention", author: nil, participants: [], timestamp: Date(), url: nil, threadID: nil)
        ])

        let planner = QueryPlanner()
        let mentionPlan = planner.plan("any mention of rss on my notes?")
        XCTAssertEqual(mentionPlan.mode, .exactLookup)
        XCTAssertEqual(mentionPlan.lookupScope, .mention)
        XCTAssertEqual(mentionPlan.keywords, ["rss"])
        let mentionHits = try await index.search(plan: mentionPlan, limit: 20)
        XCTAssertEqual(Set(mentionHits.map(\.record.id)), ["note-title-rss", "note-title-RSS", "note-browser", "note-contract"])
        XCTAssertTrue(mentionHits.allSatisfy { $0.matchedSnippet?.localizedCaseInsensitiveContains("rss") == true })

        let topicPlan = planner.plan("any notes about rss?")
        XCTAssertEqual(topicPlan.lookupScope, .topic)
        let topicHits = try await index.search(plan: topicPlan, limit: 20)
        XCTAssertEqual(Set(topicHits.map(\.record.id)), ["note-title-rss", "note-title-RSS"])

        let titlePlan = planner.plan("find a note titled rss")
        XCTAssertEqual(titlePlan.lookupScope, .title)
        let titleHits = try await index.search(plan: titlePlan, limit: 20)
        XCTAssertEqual(Set(titleHits.map(\.record.id)), ["note-title-rss", "note-title-RSS"])
    }

    func testPersistentIndexCountsAndSearchSurviveCoordinatorRelaunch() async throws {
        let databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("local-digest-relaunch-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-shm")
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-wal")
        }
        let record = IndexedRecord(id: "mail-persisted", source: .mail, title: "Persisted message", body: "survives relaunch", author: "sender@example.test", participants: [], timestamp: Date(), url: nil, threadID: nil)
        let firstIndex = SQLiteIndex(databaseURL: databaseURL)
        try await firstIndex.upsert([record])
        let firstCoordinator = IndexCoordinator(index: firstIndex, adapters: [SnapshotSourceAdapter(source: .mail, records: [])])
        let firstStatus = await firstCoordinator.statuses().first { $0.source == .mail }
        XCTAssertEqual(firstStatus?.indexedCount, 1)

        let relaunchedIndex = SQLiteIndex(databaseURL: databaseURL)
        let relaunchedCoordinator = IndexCoordinator(index: relaunchedIndex, adapters: [SnapshotSourceAdapter(source: .mail, records: [])])
        let relaunchedStatus = await relaunchedCoordinator.statuses().first { $0.source == .mail }
        XCTAssertEqual(relaunchedStatus?.indexedCount, 1)
        let hits = try await relaunchedCoordinator.search(plan: QueryPlan(
            originalQuestion: "survives relaunch",
            keywords: ["survives", "relaunch"],
            constraints: SearchConstraints(person: nil, personTerms: [], startDate: nil, endDate: nil, sources: [.mail]),
            needsConversationExpansion: false,
            ambiguity: []
        ))
        XCTAssertEqual(hits.map(\.record.id), ["mail-persisted"])
    }

    func testMailAndNotesAutomationTargetsAreAppAttributedWithoutProbingTCC() {
        XCTAssertEqual(AppleScriptRunner.automationBundleIdentifier(for: .mail), "com.apple.mail")
        XCTAssertEqual(AppleScriptRunner.automationBundleIdentifier(for: .notes), "com.apple.Notes")
        XCTAssertNil(AppleScriptRunner.automationBundleIdentifier(for: .messages))
    }

    func testExplicitDateAndMorningFollowUpReplacePriorDateButKeepIdentityAndSources() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = ISO8601DateFormatter().date(from: "2026-08-20T10:00:00Z")!
        let planner = QueryPlanner(
            dateParser: DatePhraseParser(calendar: calendar, now: { now }),
            identityResolver: IdentityResolver(identities: [
                ContactIdentity(id: "rui", displayName: "Rui Almeida", aliases: ["Rui"], handles: ["rui@example.test"])
            ])
        )

        let first = planner.plan("What did Rui tell me last night?")
        let followUp = planner.plan("What about this morning?", context: first)

        XCTAssertEqual(first.constraints.sources, [.mail, .messages])
        XCTAssertEqual(followUp.constraints.person, "Rui Almeida")
        XCTAssertEqual(followUp.constraints.personTerms, first.constraints.personTerms)
        XCTAssertEqual(followUp.constraints.startDate, ISO8601DateFormatter().date(from: "2026-08-20T05:00:00Z"))
        XCTAssertEqual(followUp.constraints.endDate, ISO8601DateFormatter().date(from: "2026-08-20T12:00:00Z"))
        XCTAssertFalse(followUp.constraints.startDate == first.constraints.startDate)
        XCTAssertTrue(followUp.needsConversationExpansion)
    }

    func testCommunicationPlanExcludesContactsFromEvidenceSources() {
        let planner = QueryPlanner(identityResolver: IdentityResolver(identities: [
            ContactIdentity(id: "rui", displayName: "Rui Almeida", aliases: ["Rui"], handles: ["+351 912 345 678"])
        ]))

        let plan = planner.plan("What did Rui say on Jan 9, 2026?")

        XCTAssertEqual(plan.constraints.sources, [.mail, .messages])
        XCTAssertTrue(plan.constraints.startDate! < plan.constraints.endDate!)
        XCTAssertTrue(plan.constraints.startDate! >= Date(timeIntervalSince1970: 1_767_916_800))
        XCTAssertFalse(plan.keywords.contains("jan"))
        XCTAssertFalse(plan.keywords.contains("2026"))
        XCTAssertTrue(PromptBuilder.instructions.contains("date"))
    }

    func testIdentityResolverMatchesAliasesAndHandles() {
        let resolver = IdentityResolver(identities: [
            ContactIdentity(id: "1", displayName: "Rui Almeida", aliases: ["Rui"], handles: ["rui@example.test"]),
            ContactIdentity(id: "2", displayName: "Marta Chen", aliases: ["Marta"], handles: ["marta@example.test"])
        ])
        XCTAssertEqual(resolver.resolve("rui@example.test").first?.displayName, "Rui Almeida")
    }

    func testPlannerIdentifiesConversationAndSourceSafeKeywords() {
        let planner = QueryPlanner(dateParser: DatePhraseParser(now: { Date(timeIntervalSince1970: 1_750_000_000) }))
        let plan = planner.plan("Summarize our conversation about the shipment last night")
        XCTAssertTrue(plan.needsConversationExpansion)
        XCTAssertTrue(plan.isConstrainedByDate)
        XCTAssertTrue(plan.keywords.contains("shipment"))
    }

    func testPlannerExtractsPersonFromNaturalQuestion() {
        let planner = QueryPlanner(
            dateParser: DatePhraseParser(now: { Date(timeIntervalSince1970: 1_750_000_000) }),
            identityResolver: IdentityResolver(identities: [
                ContactIdentity(id: "1", displayName: "Rui Almeida", aliases: ["Rui"], handles: ["rui@example.test"])
            ])
        )
        let plan = planner.plan("What did Rui tell me last night?")
        XCTAssertEqual(plan.constraints.person, "Rui Almeida")
        XCTAssertTrue(plan.constraints.personTerms.contains("rui@example.test"))
    }

    func testPlannerReportsAmbiguousPeopleInsteadOfSilentlyChoosingOne() {
        let planner = QueryPlanner(identityResolver: IdentityResolver(identities: [
            ContactIdentity(id: "1", displayName: "Rui Almeida", aliases: ["Rui"], handles: ["rui.almeida@example.test"]),
            ContactIdentity(id: "2", displayName: "Rui Santos", aliases: ["Rui"], handles: ["rui.santos@example.test"])
        ]))

        let plan = planner.plan("What did Rui tell me last night?")

        XCTAssertEqual(Set(plan.ambiguity), Set(["Rui Almeida", "Rui Santos"]))
    }

    func testSQLiteSearchReturnsConstrainedHistoricalEvidence() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-digest-test-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let index = SQLiteIndex(databaseURL: databaseURL)
        let calendar = Calendar(identifier: .gregorian)
        let older = calendar.date(from: DateComponents(year: 2026, month: 8, day: 19, hour: 20))!
        let newer = calendar.date(from: DateComponents(year: 2026, month: 8, day: 20, hour: 9))!
        try await index.upsert([
            IndexedRecord(id: "contact-rui", source: .contacts, title: "Rui Almeida", body: "rui@example.test", author: "Rui Almeida", participants: ["rui@example.test"], timestamp: newer, url: nil, threadID: nil),
            // The message row contains only the resolved phone handle, not
            // Rui's display name. This is the failure mode the FTS terms must
            // cover.
            IndexedRecord(id: "message-older", source: .messages, title: "+351 912 345 678", body: "The shipment leaves tonight.", author: "+351 912 345 678", participants: ["+351 912 345 678"], timestamp: older, url: nil, threadID: "chat-rui"),
            IndexedRecord(id: "message-newer", source: .messages, title: "+351 912 345 678", body: "The shipment arrived.", author: "+351 912 345 678", participants: ["+351 912 345 678"], timestamp: newer, url: nil, threadID: "chat-rui")
        ])

        let parser = DatePhraseParser(calendar: calendar, now: { newer })
        let planner = QueryPlanner(dateParser: parser, identityResolver: IdentityResolver(identities: [
            ContactIdentity(id: "rui", displayName: "Rui Almeida", aliases: ["Rui"], handles: ["+351 912 345 678"])
        ]))
        let plan = planner.plan("What did Rui tell me last night?")
        let hits = try await index.search(plan: plan, limit: 10)

        XCTAssertEqual(hits.map { $0.record.id }, ["message-older"])
    }

    func testSQLiteSearchSupportsPersonOnlyAndDateOnlyPlans() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-digest-person-only-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let index = SQLiteIndex(databaseURL: databaseURL)
        let timestamp = Date(timeIntervalSince1970: 1_750_000_000)
        try await index.upsert([
            IndexedRecord(id: "person-match", source: .messages, title: "Message", body: "The detail is in the attachment.", author: "rui@example.test", participants: ["rui@example.test"], timestamp: timestamp, url: nil, threadID: "chat-rui"),
            IndexedRecord(id: "date-match", source: .notes, title: "A note", body: "A date-only fixture.", author: nil, participants: [], timestamp: timestamp, url: nil, threadID: nil)
        ])

        let personPlan = QueryPlan(
            originalQuestion: "Rui",
            keywords: [],
            constraints: SearchConstraints(person: "Rui Almeida", personTerms: ["rui@example.test"], startDate: nil, endDate: nil, sources: [.messages]),
            needsConversationExpansion: false,
            ambiguity: []
        )
        let personHits = try await index.search(plan: personPlan)
        XCTAssertEqual(personHits.map(\.record.id), ["person-match"])

        let datePlan = QueryPlan(
            originalQuestion: "What happened today?",
            keywords: [],
            constraints: SearchConstraints(person: nil, personTerms: [], startDate: timestamp.addingTimeInterval(-1), endDate: timestamp.addingTimeInterval(1), sources: [.notes]),
            needsConversationExpansion: false,
            ambiguity: []
        )
        let dateHits = try await index.search(plan: datePlan)
        XCTAssertEqual(dateHits.map(\.record.id), ["date-match"])
    }

    func testDateOnlySearchAppliesDateBeforeCandidateLimit() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-digest-old-date-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let index = SQLiteIndex(databaseURL: databaseURL)
        let oldDate = Date(timeIntervalSince1970: 1_000)
        var records = [IndexedRecord(id: "old-target", source: .notes, title: "Old target", body: "Historical detail", author: nil, participants: [], timestamp: oldDate, url: nil, threadID: nil)]
        records += (0..<5_100).map { offset in
            IndexedRecord(id: "new-\(offset)", source: .notes, title: "New", body: "Recent detail", author: nil, participants: [], timestamp: Date(timeIntervalSince1970: 10_000 + Double(offset)), url: nil, threadID: nil)
        }
        try await index.upsert(records)
        let plan = QueryPlan(
            originalQuestion: "What happened then?",
            keywords: [],
            constraints: SearchConstraints(person: nil, personTerms: [], startDate: oldDate.addingTimeInterval(-1), endDate: oldDate.addingTimeInterval(1), sources: [.notes]),
            needsConversationExpansion: false,
            ambiguity: []
        )

        let hits = try await index.search(plan: plan)

        XCTAssertEqual(hits.map(\.record.id), ["old-target"])
    }

    func testConversationExpansionAddsBoundedChronologicalThreadContext() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-digest-conversation-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let index = SQLiteIndex(databaseURL: databaseURL)
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        try await index.upsert([
            IndexedRecord(id: "thread-before", source: .messages, title: "Rui", body: "I can send the address first.", author: "Rui", participants: ["rui@example.test"], timestamp: start, url: nil, threadID: "chat-rui"),
            IndexedRecord(id: "thread-match", source: .messages, title: "Rui", body: "The shipment leaves at nine.", author: "Rui", participants: ["rui@example.test"], timestamp: start.addingTimeInterval(60), url: nil, threadID: "chat-rui"),
            IndexedRecord(id: "thread-after", source: .messages, title: "Me", body: "Thanks, I will be ready.", author: "Me", participants: ["rui@example.test", "Me"], timestamp: start.addingTimeInterval(120), url: nil, threadID: "chat-rui")
        ])

        let plan = QueryPlan(
            originalQuestion: "Summarize our conversation about the shipment",
            keywords: ["shipment"],
            constraints: SearchConstraints(person: nil, personTerms: [], startDate: start.addingTimeInterval(-1), endDate: start.addingTimeInterval(300), sources: [.messages]),
            needsConversationExpansion: true,
            ambiguity: []
        )
        let hits = try await index.search(plan: plan, limit: 10)

        XCTAssertEqual(hits.map(\.record.id), ["thread-before", "thread-match", "thread-after"])
    }

    func testPromptMarksRetrievedTextAsUntrustedAndBoundsEvidence() {
        let evidence = (0..<24).map { index in
            let body = "fixture-\(index) " + String(repeating: "untrusted message ", count: 500)
            return SearchHit(record: IndexedRecord(id: "note-\(index)", source: .notes, title: "Fixture", body: body, author: nil, participants: [], timestamp: Date(), url: nil, threadID: nil), score: 1)
        }
        let prompt = PromptBuilder.makePrompt(question: "Summarize this", evidence: evidence)

        XCTAssertTrue(PromptBuilder.instructions.localizedCaseInsensitiveContains("untrusted"))
        XCTAssertTrue(prompt.contains("Content (untrusted):"))
        XCTAssertLessThanOrEqual(prompt.count, 4_000)
    }

    func testModelPromptUsesMeasuredEightKContextAndReservesResponseSpace() async {
        let evidence = (0..<24).map { index in
            SearchHit(
                record: IndexedRecord(
                    id: "note-\(index)",
                    source: .notes,
                    title: "Fixture \(index)",
                    body: String(repeating: "untrusted message ", count: 90),
                    author: nil,
                    participants: [],
                    timestamp: Date(timeIntervalSince1970: Double(index)),
                    url: nil,
                    threadID: nil
                ),
                score: 1
            )
        }

        let result = await PromptBuilder.makeModelPrompt(
            question: "Summarize this",
            evidence: evidence,
            contextSize: 8_192,
            instructionTokenCount: 120,
            tokenCounter: { prompt in
                PromptBuilder.estimatedTokenCount(for: prompt)
            }
        )

        XCTAssertEqual(result.contextSize, 8_192)
        XCTAssertGreaterThan(result.prompt.count, PromptBuilder.maxPromptCharacters)
        XCTAssertEqual(result.responseTokenBudget, PromptBuilder.responseTokenBudget)
        XCTAssertLessThanOrEqual(
            result.promptTokenCount + 120 + result.responseTokenBudget + PromptBuilder.contextSafetyMargin,
            result.contextSize
        )
    }

    func testModelPromptFallsBackWhenRuntimeContextIsUnavailable() async {
        let result = await PromptBuilder.makeModelPrompt(
            question: "What happened?",
            evidence: [],
            contextSize: 0,
            instructionTokenCount: 10
        )

        XCTAssertEqual(result.contextSize, PromptBuilder.fallbackContextSize)
        XCTAssertEqual(result.responseTokenBudget, 512)
    }

    func testModelPromptReservesPersistentSessionHistory() async {
        let result = await PromptBuilder.makeModelPrompt(
            question: "What about this morning?",
            evidence: [],
            contextSize: 8_192,
            instructionTokenCount: 120,
            historyTokenCount: 3_000,
            tokenCounter: { prompt in PromptBuilder.estimatedTokenCount(for: prompt) }
        )

        XCTAssertLessThanOrEqual(
            result.promptTokenCount + 120 + 3_000 + result.responseTokenBudget + PromptBuilder.contextSafetyMargin,
            result.contextSize
        )
    }

    func testMessagesPermissionStateDoesNotClaimAccessWhenDatabaseIsUnavailable() async {
        let status = await MessagesSourceAdapter().status()
        XCTAssertTrue([SourcePermission.authorized, .denied, .unavailable].contains(status.permission))
        if status.permission != .authorized {
            XCTAssertFalse(status.message?.isEmpty ?? true)
        }
    }

    func testMailIndexingUsesBoundedMessageChunks() {
        XCTAssertEqual(MailSourceAdapter.messageRanges(count: 0), [])
        XCTAssertEqual(MailSourceAdapter.messageRanges(count: 50), [1...50])
        XCTAssertEqual(MailSourceAdapter.messageRanges(count: 121), [1...50, 51...100, 101...121])
        XCTAssertTrue(MailSourceAdapter.messageRanges(count: 121).allSatisfy { $0.count <= 50 })
    }

    func testMailRecordScriptInterpolatesNumericIndicesAndCompilesWithoutExecutingMail() throws {
        let script = MailSourceAdapter.recordsScript(accountIndex: 2, mailboxIndex: 7, range: 101...150)
        XCTAssertTrue(script.contains("set targetAccount to account 2"))
        XCTAssertTrue(script.contains("set targetMailbox to mailbox 7 of targetAccount"))
        XCTAssertTrue(script.contains("messages 101 thru endIndex of targetMailbox"))
        XCTAssertFalse(script.contains("mailbox.accountIndex"))
        XCTAssertFalse(script.contains("range.lowerBound"))

        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("local-digest-mail-script-\(UUID().uuidString).applescript")
        let compiledURL = FileManager.default.temporaryDirectory.appendingPathComponent("local-digest-mail-script-\(UUID().uuidString).scpt")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: compiledURL)
        }
        try script.write(to: sourceURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
        process.arguments = ["-o", compiledURL.path, sourceURL.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, error)
    }

    func testIncrementalAppleScriptsUseDateWatermarksAndCompileWithoutAccessingSources() throws {
        let mailScript = MailSourceAdapter.incrementalRecordsScript(accountIndex: 2, mailboxIndex: 7, lookbackSeconds: 604_800)
        XCTAssertTrue(mailScript.contains("whose date received"))
        XCTAssertTrue(mailScript.contains("current date"))
        XCTAssertTrue(mailScript.contains("604800"))

        let notesScript = NotesSourceAdapter.recordsScript(lookbackSeconds: 604_800)
        XCTAssertTrue(notesScript.contains("whose modification date"))
        XCTAssertTrue(notesScript.contains("modification date of n"))

        for (label, script) in [("mail", mailScript), ("notes", notesScript)] {
            let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("local-digest-\(label)-incremental-\(UUID().uuidString).applescript")
            let compiledURL = FileManager.default.temporaryDirectory.appendingPathComponent("local-digest-\(label)-incremental-\(UUID().uuidString).scpt")
            defer {
                try? FileManager.default.removeItem(at: sourceURL)
                try? FileManager.default.removeItem(at: compiledURL)
            }
            try script.write(to: sourceURL, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
            process.arguments = ["-o", compiledURL.path, sourceURL.path]
            let errorPipe = Pipe()
            process.standardError = errorPipe
            try process.run()
            process.waitUntilExit()
            let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            XCTAssertEqual(process.terminationStatus, 0, "\(label): \(error)")
        }
    }

    func testOutOfProcessAppleScriptKeepsMainActorResponsiveAndCanCancel() async throws {
        let heartbeat = MainActorHeartbeat()
        let scriptTask = Task {
            try await AppleScriptRunner.run("delay 1\nreturn \"heartbeat\"", source: .notes)
        }
        let heartbeatTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            await heartbeat.mark()
        }

        let heartbeatObserved = await waitUntil(timeout: .milliseconds(700)) {
            await heartbeat.value()
        }
        XCTAssertTrue(heartbeatObserved)
        let scriptOutput = try await scriptTask.value
        XCTAssertEqual(scriptOutput, "heartbeat")
        heartbeatTask.cancel()

        let cancellable = Task {
            try await AppleScriptRunner.run("delay 5\nreturn \"should not finish\"", source: .notes)
        }
        try? await Task.sleep(for: .milliseconds(100))
        cancellable.cancel()
        do {
            _ = try await cancellable.value
            XCTFail("Cancelled AppleScript should terminate its child process.")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected cancellation, got \(error)")
        }
    }

    func testMessagesBodyExtractionDistinguishesTextEmojiPlaceholdersAndAttributedFallback() throws {
        XCTAssertEqual(MessagesSourceAdapter.messageBody(text: "recebido", attributedBody: nil), "recebido")
        XCTAssertEqual(MessagesSourceAdapter.messageBody(text: "👍", attributedBody: nil), "👍")
        XCTAssertNil(MessagesSourceAdapter.messageBody(text: "\u{FFFC}", attributedBody: nil))
        XCTAssertNil(MessagesSourceAdapter.messageBody(text: " \n\t", attributedBody: nil))

        let attributedData = try NSKeyedArchiver.archivedData(
            withRootObject: NSAttributedString(string: "recent attributed message"),
            requiringSecureCoding: false
        )
        XCTAssertEqual(
            MessagesSourceAdapter.messageBody(text: nil, attributedBody: attributedData),
            "recent attributed message"
        )
        XCTAssertTrue(MessagesSourceAdapter.recordsQuery(includesAttributedBody: true).contains("message.attributedBody IS NOT NULL"))
    }

    func testRecentAttributedBodyOnlyMessageIsSelectedBeforeNativeFallback() throws {
        let recentDate = Date().addingTimeInterval(-60)
        let attributedData = try NSKeyedArchiver.archivedData(
            withRootObject: NSAttributedString(string: "received today"),
            requiringSecureCoding: false
        )

        // This is the shape of a newer Messages row: text is NULL, the
        // attributed body carries the actual message, and the date is recent.
        XCTAssertNil(MessagesSourceAdapter.messageBody(text: nil, attributedBody: nil))
        XCTAssertEqual(
            MessagesSourceAdapter.messageBody(text: nil, attributedBody: attributedData),
            "received today"
        )
        let query = MessagesSourceAdapter.recordsQuery(includesAttributedBody: true)
        XCTAssertTrue(query.contains("message.attributedBody IS NOT NULL"))
        XCTAssertTrue(query.contains("ORDER BY message.date DESC"))
        XCTAssertGreaterThan(recentDate, Date().addingTimeInterval(-300))
    }

    func testMessagesDateDecodingHandlesReferenceSecondsAndNanoseconds() {
        let referenceInterval = 800_000_000.0
        XCTAssertEqual(
            MessagesSourceAdapter.messageDate(from: referenceInterval),
            Date(timeIntervalSinceReferenceDate: referenceInterval)
        )
        XCTAssertEqual(
            MessagesSourceAdapter.messageDate(from: referenceInterval * 1_000_000_000),
            Date(timeIntervalSinceReferenceDate: referenceInterval)
        )
    }

    func testMessagesDeduplicateJoinRowsDeterministicallyAndMergeParticipants() {
        let timestamp = Date(timeIntervalSince1970: 1_750_000_000)
        let records = [
            IndexedRecord(id: "message-guid", source: .messages, title: "Rui", body: "A message", author: "rui@example.test", participants: ["chat-b", "rui@example.test"], timestamp: timestamp, url: nil, threadID: "chat-b"),
            IndexedRecord(id: "message-guid", source: .messages, title: "Rui", body: "A message", author: "rui@example.test", participants: ["chat-a"], timestamp: timestamp, url: nil, threadID: "chat-a")
        ]

        let deduplicated = MessagesSourceAdapter.deduplicate(records)

        XCTAssertEqual(deduplicated.count, 1)
        XCTAssertEqual(deduplicated[0].participants, ["chat-a", "chat-b", "rui@example.test"])
        XCTAssertEqual(deduplicated[0].threadID, "chat-a")
    }

    func testSuccessfulSnapshotReplacementRemovesStaleMessagesAndKeepsOtherSources() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-digest-snapshot-replacement-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-shm")
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-wal")
        }

        let index = SQLiteIndex(databaseURL: databaseURL)
        try await index.upsert([
            IndexedRecord(id: "message-stale", source: .messages, title: "Rui", body: "old placeholder", author: "Rui", participants: [], timestamp: Date(timeIntervalSince1970: 1_000), url: nil, threadID: "chat-rui"),
            IndexedRecord(id: "note-keep", source: .notes, title: "Keep this note", body: "unrelated source remains", author: nil, participants: [], timestamp: Date(timeIntervalSince1970: 1_000), url: nil, threadID: nil)
        ])

        let coordinator = IndexCoordinator(
            index: index,
            adapters: [SnapshotSourceAdapter(
                source: .messages,
                records: [IndexedRecord(id: "message-fresh", source: .messages, title: "Rui", body: "received today", author: "Rui", participants: [], timestamp: Date(), url: nil, threadID: "chat-rui")]
            )]
        )
        _ = await coordinator.indexAll { _, _, _ in }

        let staleHits = try await index.search(plan: QueryPlan(
            originalQuestion: "old",
            keywords: ["old"],
            constraints: SearchConstraints(person: nil, personTerms: [], startDate: nil, endDate: nil, sources: [.messages]),
            needsConversationExpansion: false,
            ambiguity: []
        ))
        XCTAssertTrue(staleHits.isEmpty)

        let freshHits = try await index.search(plan: QueryPlan(
            originalQuestion: "today",
            keywords: ["today"],
            constraints: SearchConstraints(person: nil, personTerms: [], startDate: nil, endDate: nil, sources: [.messages]),
            needsConversationExpansion: false,
            ambiguity: []
        ))
        XCTAssertEqual(freshHits.map(\.record.id), ["message-fresh"])

        let noteHits = try await index.search(plan: QueryPlan(
            originalQuestion: "note",
            keywords: ["unrelated"],
            constraints: SearchConstraints(person: nil, personTerms: [], startDate: nil, endDate: nil, sources: [.notes]),
            needsConversationExpansion: false,
            ambiguity: []
        ))
        XCTAssertEqual(noteHits.map(\.record.id), ["note-keep"])
    }

    func testFailedOrUnavailableSnapshotDoesNotEraseExistingRecords() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-digest-snapshot-failure-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-shm")
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-wal")
        }

        let index = SQLiteIndex(databaseURL: databaseURL)
        let existing = IndexedRecord(id: "message-existing", source: .messages, title: "Rui", body: "existing message", author: "Rui", participants: [], timestamp: Date(), url: nil, threadID: "chat-rui")
        try await index.upsert([existing])

        let failedCoordinator = IndexCoordinator(
            index: index,
            adapters: [SnapshotSourceAdapter(source: .messages, records: [], shouldFail: true)]
        )
        _ = await failedCoordinator.indexAll { _, _, _ in }
        let failedHits = try await index.search(plan: messagePlan(keywords: ["existing"]))
        XCTAssertEqual(failedHits.map(\.record.id), ["message-existing"])

        let unavailableCoordinator = IndexCoordinator(
            index: index,
            adapters: [SnapshotSourceAdapter(source: .messages, records: [], permission: .unavailable)]
        )
        _ = await unavailableCoordinator.indexAll { _, _, _ in }
        let unavailableHits = try await index.search(plan: messagePlan(keywords: ["existing"]))
        XCTAssertEqual(unavailableHits.map(\.record.id), ["message-existing"])
    }

    func testIndexingSourcesDoesNotWaitForEarlierSlowSource() async {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-digest-parallel-index-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-shm")
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-wal")
        }

        let slowSourceGate = SourceFetchGate()
        let progress = IndexProgressRecorder()
        let coordinator = IndexCoordinator(
            index: SQLiteIndex(databaseURL: databaseURL),
            adapters: [
                TestSourceAdapter(source: .mail, gate: slowSourceGate),
                TestSourceAdapter(source: .notes)
            ]
        )

        let indexingTask = Task {
            await coordinator.indexAll { source, count, total in
                Task { await progress.record(source: source, count: count, total: total) }
            }
        }

        let notesFinishedFirst = await waitUntil {
            await progress.contains(source: .notes, count: 1, total: 1)
        }
        let mailFinishedEarly = await progress.contains(source: .mail, count: 1, total: 1)

        await slowSourceGate.open()
        let statuses = await indexingTask.value

        XCTAssertTrue(notesFinishedFirst)
        XCTAssertFalse(mailFinishedEarly)
        XCTAssertEqual(statuses.first(where: { $0.source == .mail })?.indexedCount, 1)
        XCTAssertEqual(statuses.first(where: { $0.source == .notes })?.indexedCount, 1)
    }

    func testSearchRemainsReadableDuringRefreshAndNewSnapshotAppearsAfterCommit() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-digest-refresh-read-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-shm")
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-wal")
        }

        let index = SQLiteIndex(databaseURL: databaseURL)
        try await index.upsert([
            IndexedRecord(
                id: "message-before-refresh",
                source: .messages,
                title: "Rui",
                body: "old committed evidence",
                author: "Rui",
                participants: ["rui@example.test"],
                timestamp: Date(timeIntervalSince1970: 1_750_000_000),
                url: nil,
                threadID: "chat-rui"
            )
        ])

        let gate = SourceFetchGate()
        let progress = IndexProgressRecorder()
        let coordinator = IndexCoordinator(
            index: index,
            adapters: [
                TestSourceAdapter(
                    source: .messages,
                    gate: gate,
                    records: [
                        IndexedRecord(
                            id: "message-after-refresh",
                            source: .messages,
                            title: "Rui",
                            body: "new committed evidence",
                            author: "Rui",
                            participants: ["rui@example.test"],
                            timestamp: Date(),
                            url: nil,
                            threadID: "chat-rui"
                        )
                    ]
                )
            ]
        )

        let refresh = Task {
            await coordinator.indexAll { source, count, total in
                Task { await progress.record(source: source, count: count, total: total) }
            }
        }
        let refreshStarted = await waitUntil {
            await progress.contains(source: .messages, count: 0, total: -1)
        }
        XCTAssertTrue(refreshStarted)

        // This query uses the reader connection while the source fetch is
        // blocked. It must see the last committed generation immediately.
        let duringRefresh = try await coordinator.search(plan: messagePlan(keywords: ["old"]))
        XCTAssertEqual(duringRefresh.map(\.record.id), ["message-before-refresh"])

        await gate.open()
        _ = await refresh.value

        let afterCommit = try await coordinator.search(plan: messagePlan(keywords: ["new"]))
        XCTAssertEqual(afterCommit.map(\.record.id), ["message-after-refresh"])
        let staleAfterCommit = try await coordinator.search(plan: messagePlan(keywords: ["old"]))
        XCTAssertTrue(staleAfterCommit.isEmpty)
    }

    func testDuplicateRefreshIsCoalescedUntilTheFirstRefreshCompletes() async {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-digest-refresh-coalescing-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-shm")
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-wal")
        }

        let gate = SourceFetchGate()
        let fetchCounter = FetchCounter()
        let completion = RefreshCompletion()
        let coordinator = IndexCoordinator(
            index: SQLiteIndex(databaseURL: databaseURL),
            adapters: [CountingSourceAdapter(source: .messages, gate: gate, counter: fetchCounter)]
        )

        let first = Task {
            await coordinator.indexAll { _, _, _ in }
        }
        let firstFetchStarted = await waitUntil { await fetchCounter.value() == 1 }
        XCTAssertTrue(firstFetchStarted)

        let duplicate = Task {
            _ = await coordinator.indexAll { _, _, _ in }
            await completion.mark()
        }
        let duplicateFinished = await waitUntil { await completion.value() }
        XCTAssertTrue(duplicateFinished)
        let fetchesBeforeRelease = await fetchCounter.value()
        XCTAssertEqual(fetchesBeforeRelease, 1)

        await gate.open()
        _ = await first.value
        let totalFetches = await fetchCounter.value()
        XCTAssertEqual(totalFetches, 1)
    }

    func testIncrementalSyncMergesNewRecordsAndFullRebuildReconciles() async throws {
        let cursorKey = "LocalDigest.cursor.messages"
        UserDefaults.standard.removeObject(forKey: cursorKey)
        defer { UserDefaults.standard.removeObject(forKey: cursorKey) }

        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-digest-incremental-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-shm")
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-wal")
        }

        let initial = IndexedRecord(id: "message-initial", source: .messages, title: "Rui", body: "initial committed", author: "Rui", participants: [], timestamp: Date(timeIntervalSince1970: 1_700_000_000), url: nil, threadID: "chat")
        let newRecord = IndexedRecord(id: "message-new", source: .messages, title: "Rui", body: "new today", author: "Rui", participants: [], timestamp: Date(timeIntervalSince1970: 1_700_000_100), url: nil, threadID: "chat")
        let rebuilt = IndexedRecord(id: "message-rebuilt", source: .messages, title: "Rui", body: "reconciled full rebuild", author: "Rui", participants: [], timestamp: Date(timeIntervalSince1970: 1_700_000_200), url: nil, threadID: "chat")
        let initialCursor = SourceCursor(watermark: initial.timestamp, rawWatermark: 1_000, rowID: 10, stableID: initial.id)
        let nextCursor = SourceCursor(watermark: newRecord.timestamp, rawWatermark: 2_000, rowID: 20, stableID: newRecord.id)
        let calls = CursorFixtureCalls()
        let index = SQLiteIndex(databaseURL: databaseURL)

        let firstCoordinator = IndexCoordinator(
            index: index,
            adapters: [CursorFixtureAdapter(source: .messages, initial: [initial], delta: [newRecord], rebuild: [rebuilt], initialCursor: initialCursor, nextCursor: nextCursor, calls: calls)]
        )
        _ = await firstCoordinator.indexAll { _, _, _ in }

        let secondCoordinator = IndexCoordinator(
            index: index,
            adapters: [CursorFixtureAdapter(source: .messages, initial: [initial], delta: [newRecord], rebuild: [rebuilt], initialCursor: initialCursor, nextCursor: nextCursor, calls: calls)]
        )
        _ = await secondCoordinator.indexAll { _, _, _ in }

        let recordedCursors = await calls.values()
        XCTAssertEqual(recordedCursors.count, 2)
        XCTAssertNil(recordedCursors[0])
        XCTAssertEqual(recordedCursors[1], initialCursor)
        let initialHits = try await index.search(plan: messagePlan(keywords: ["initial"]))
        XCTAssertEqual(initialHits.map(\.record.id), ["message-initial"])
        let newHits = try await index.search(plan: messagePlan(keywords: ["today"]))
        XCTAssertEqual(newHits.map(\.record.id), ["message-new"])

        let failingCoordinator = IndexCoordinator(
            index: index,
            adapters: [CursorFixtureAdapter(source: .messages, initial: [initial], delta: [newRecord], rebuild: [rebuilt], initialCursor: initialCursor, nextCursor: nextCursor, calls: calls, shouldFail: true)]
        )
        _ = await failingCoordinator.indexAll { _, _, _ in }
        let preservedHits = try await index.search(plan: messagePlan(keywords: ["today"]))
        XCTAssertEqual(preservedHits.map(\.record.id), ["message-new"])
        let callsAfterFailure = await calls.values()
        XCTAssertEqual(callsAfterFailure.last, nextCursor)

        let fullRebuildCoordinator = IndexCoordinator(
            index: index,
            adapters: [CursorFixtureAdapter(source: .messages, initial: [initial], delta: [newRecord], rebuild: [rebuilt], initialCursor: initialCursor, nextCursor: nextCursor, calls: calls)]
        )
        _ = await fullRebuildCoordinator.indexAll(mode: .fullRebuild) { _, _, _ in }
        let removedHits = try await index.search(plan: messagePlan(keywords: ["initial"]))
        XCTAssertTrue(removedHits.isEmpty)
        let rebuiltHits = try await index.search(plan: messagePlan(keywords: ["reconciled"]))
        XCTAssertEqual(rebuiltHits.map(\.record.id), ["message-rebuilt"])
    }
}

private func messagePlan(keywords: [String]) -> QueryPlan {
    QueryPlan(
        originalQuestion: keywords.joined(separator: " "),
        keywords: keywords,
        constraints: SearchConstraints(person: nil, personTerms: [], startDate: nil, endDate: nil, sources: [.messages]),
        needsConversationExpansion: false,
        ambiguity: []
    )
}

private struct SnapshotSourceAdapter: SourceAdapter {
    let source: SourceKind
    let records: [IndexedRecord]
    let permission: SourcePermission
    let shouldFail: Bool

    init(source: SourceKind, records: [IndexedRecord], permission: SourcePermission = .authorized, shouldFail: Bool = false) {
        self.source = source
        self.records = records
        self.permission = permission
        self.shouldFail = shouldFail
    }

    func status() async -> SourceStatus {
        SourceStatus(source: source, permission: permission, indexedCount: 0, isIndexing: false, message: nil)
    }

    func requestAccess() async -> SourceStatus { await status() }

    func fetchRecords() async throws -> [IndexedRecord] {
        if shouldFail { throw SourceAdapterError.unavailable(source, "Fixture fetch failed") }
        return records
    }
}

private struct TestSourceAdapter: SourceAdapter {
    let source: SourceKind
    var gate: SourceFetchGate?
    let records: [IndexedRecord]

    init(source: SourceKind, gate: SourceFetchGate? = nil, records: [IndexedRecord]? = nil) {
        self.source = source
        self.gate = gate
        self.records = records ?? [IndexedRecord(
            id: "\(source.rawValue)-fixture",
            source: source,
            title: "Fixture",
            body: "Fixture body",
            author: nil,
            participants: [],
            timestamp: Date(),
            url: nil,
            threadID: nil
        )]
    }

    func status() async -> SourceStatus {
        SourceStatus(source: source, permission: .authorized, indexedCount: 0, isIndexing: false, message: nil)
    }

    func requestAccess() async -> SourceStatus { await status() }

    func fetchRecords() async throws -> [IndexedRecord] {
        if let gate { await gate.wait() }
        return records
    }
}

private struct CountingSourceAdapter: SourceAdapter {
    let source: SourceKind
    let gate: SourceFetchGate
    let counter: FetchCounter

    func status() async -> SourceStatus {
        SourceStatus(source: source, permission: .authorized, indexedCount: 0, isIndexing: false, message: nil)
    }

    func requestAccess() async -> SourceStatus { await status() }

    func fetchRecords() async throws -> [IndexedRecord] {
        await counter.increment()
        await gate.wait()
        return [IndexedRecord(
            id: "\(source.rawValue)-counted",
            source: source,
            title: "Counted",
            body: "Counted fixture",
            author: nil,
            participants: [],
            timestamp: Date(),
            url: nil,
            threadID: nil
        )]
    }
}

private struct CursorFixtureAdapter: SourceAdapter {
    let source: SourceKind
    let initial: [IndexedRecord]
    let delta: [IndexedRecord]
    let rebuild: [IndexedRecord]
    let initialCursor: SourceCursor
    let nextCursor: SourceCursor
    let calls: CursorFixtureCalls
    let shouldFail: Bool

    init(source: SourceKind, initial: [IndexedRecord], delta: [IndexedRecord], rebuild: [IndexedRecord], initialCursor: SourceCursor, nextCursor: SourceCursor, calls: CursorFixtureCalls, shouldFail: Bool = false) {
        self.source = source
        self.initial = initial
        self.delta = delta
        self.rebuild = rebuild
        self.initialCursor = initialCursor
        self.nextCursor = nextCursor
        self.calls = calls
        self.shouldFail = shouldFail
    }

    var refreshCapability: SourceRefreshCapability {
        .incremental("Fixture cursor")
    }

    func status() async -> SourceStatus {
        SourceStatus(source: source, permission: .authorized, indexedCount: 0, isIndexing: false, message: nil)
    }

    func requestAccess() async -> SourceStatus { await status() }

    func fetchRecords() async throws -> [IndexedRecord] {
        initial
    }

    func fetchRecords(mode: IndexRefreshMode, cursor: SourceCursor?) async throws -> SourceFetchBatch {
        await calls.record(cursor)
        if shouldFail {
            throw SourceAdapterError.unavailable(source, "Fixture incremental fetch failed")
        }
        if mode == .fullRebuild {
            return SourceFetchBatch(records: rebuild, nextCursor: nextCursor, isCompleteSnapshot: true)
        }
        if cursor == nil {
            return SourceFetchBatch(records: initial, nextCursor: initialCursor, isCompleteSnapshot: true)
        }
        return SourceFetchBatch(records: delta, nextCursor: nextCursor, isCompleteSnapshot: false)
    }
}

private actor SourceFetchGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor IndexProgressRecorder {
    private var events: [(source: SourceKind, count: Int, total: Int)] = []

    func record(source: SourceKind, count: Int, total: Int) {
        events.append((source, count, total))
    }

    func contains(source: SourceKind, count: Int, total: Int) -> Bool {
        events.contains { $0.source == source && $0.count == count && $0.total == total }
    }
}

private actor FetchCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

private actor CursorFixtureCalls {
    private var cursors: [SourceCursor?] = []

    func record(_ cursor: SourceCursor?) {
        cursors.append(cursor)
    }

    func values() -> [SourceCursor?] {
        cursors
    }
}

private actor RefreshCompletion {
    private var completed = false

    func mark() {
        completed = true
    }

    func value() -> Bool {
        completed
    }
}

private actor MainActorHeartbeat {
    private var didRun = false

    func mark() {
        didRun = true
    }

    func value() -> Bool {
        didRun
    }
}

private func waitUntil(
    timeout: Duration = .seconds(1),
    condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
