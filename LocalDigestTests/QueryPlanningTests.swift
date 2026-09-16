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

    func testDayFirstNumericDatesUseReferenceYearAndRejectInvalidDates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let reference = ISO8601DateFormatter().date(from: "2026-08-22T12:00:00Z")!
        let parser = DatePhraseParser(calendar: calendar, now: { reference })
        let expectedStart = ISO8601DateFormatter().date(from: "2026-08-21T00:00:00Z")!
        XCTAssertEqual(parser.parse("emails from 21/08", referenceDate: reference)?.start, expectedStart)
        XCTAssertEqual(parser.parse("emails from 21/08/2026", referenceDate: reference)?.start, expectedStart)
        XCTAssertEqual(parser.parse("emails from 21-08-2026", referenceDate: reference)?.start, expectedStart)
        XCTAssertNil(parser.parse("emails from 31/02", referenceDate: reference))
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

    @MainActor
    func testNotesHTMLIsConvertedAndUnknownDatesAreNotRendered() {
        XCTAssertEqual(NotesSourceAdapter.htmlToPlainText("<div><h1>Rss</h1></div><div>Read &amp; review</div>"), "Rss\nRead & review")
        let unknown = IndexedRecord(id: "note-unknown", source: .notes, title: "Rss", body: "rss", author: nil, participants: [], timestamp: .distantPast, url: nil, threadID: nil)
        let hit = SearchHit(record: unknown, score: 1)
        let prompt = PromptBuilder.makePrompt(question: "find a note with rss", evidence: [hit])
        XCTAssertFalse(prompt.contains("Dec 31, 1"))
        XCTAssertFalse(prompt.contains("date="))
    }

    @MainActor
    func testNotesHTMLConversionIsMainActorBound() {
        XCTAssertEqual(NotesSourceAdapter.htmlToPlainText("<p>Activity &amp; steps</p>"), "Activity & steps")
    }

    func testNoSafariSourceIsPresent() {
        XCTAssertFalse(SourceKind.allCases.contains { $0.rawValue == "safari" })
    }

    func testReminderDateNormalizationAndSingleDeliveryGate() async {
        let components = RemindersSourceAdapter.normalizedDueDateComponents(DateComponents(year: 2026, month: 8, day: 21))
        XCTAssertEqual(components.era, 1)
        let gate = SingleDeliveryGate<Int>()
        let values = await withTaskGroup(of: Int?.self, returning: [Int?].self) { group in
            for value in 0..<8 { group.addTask { gate.deliver(value) } }
            var result: [Int?] = []
            for await value in group { result.append(value) }
            return result
        }
        XCTAssertEqual(values.compactMap { $0 }.count, 1)
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
        XCTAssertNil(AppleScriptRunner.automationBundleIdentifier(for: .calendar))
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

    func testIdentityResolverConsolidatesDuplicateDisplayNamesAndUnionsHandles() {
        let resolver = IdentityResolver(identities: [
            ContactIdentity(id: "sandra-b", displayName: "Sandra Martins", aliases: ["Sandy"], handles: ["sandra.work@example.test"]),
            ContactIdentity(id: "sandra-a", displayName: "  Sándra   Martins ", aliases: ["Sandra M."], handles: ["sandra.home@example.test"]),
            ContactIdentity(id: "rafaela", displayName: "Rafaela Martins", aliases: ["Rafaela"], handles: ["rafaela@example.test"])
        ])

        let exact = resolver.resolve("Sandra Martins")
        XCTAssertEqual(exact.count, 1)
        XCTAssertEqual(exact.first?.id, "sandra-a")
        XCTAssertEqual(Set(exact.first?.handles ?? []), ["sandra.home@example.test", "sandra.work@example.test"])
        XCTAssertFalse(exact.contains { $0.displayName == "Rafaela Martins" })
        XCTAssertEqual(resolver.resolve("sandra.work@example.test").first?.id, "sandra-a")
        XCTAssertEqual(resolver.resolve("SÁNDRA MARTÍNS").count, 1)
    }

    func testPlannerUsesConsolidatedPersonTermsAndPreservesSingleNameAmbiguity() {
        let planner = QueryPlanner(identityResolver: IdentityResolver(identities: [
            ContactIdentity(id: "sandra-b", displayName: "Sandra Martins", aliases: ["Sandra"], handles: ["sandra.work@example.test"]),
            ContactIdentity(id: "sandra-a", displayName: "Sándra Martins", aliases: ["Sandra"], handles: ["sandra.home@example.test"]),
            ContactIdentity(id: "sandra-c", displayName: "Sandra Costa", aliases: ["Sandra"], handles: ["sandra.costa@example.test"]),
            ContactIdentity(id: "rafaela", displayName: "Rafaela Martins", aliases: ["Rafaela"], handles: ["rafaela@example.test"])
        ]))

        let fullName = planner.plan("What did Sandra Martins tell me?")
        XCTAssertEqual(fullName.ambiguity, [])
        XCTAssertEqual(fullName.constraints.person, "Sándra Martins")
        XCTAssertTrue(fullName.constraints.personTerms.contains("sandra.work@example.test"))
        XCTAssertTrue(fullName.constraints.personTerms.contains("sandra.home@example.test"))
        XCTAssertFalse(fullName.constraints.personTerms.contains("rafaela@example.test"))

        let firstName = planner.plan("What did Sandra tell me?")
        XCTAssertEqual(Set(firstName.ambiguity), Set(["Sándra Martins", "Sandra Costa"]))
    }

    func testConsolidatedPersonTermsRetrieveMessagesFromEitherHandle() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-digest-identity-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let index = SQLiteIndex(databaseURL: databaseURL)
        try await index.merge(source: .messages, with: [
            IndexedRecord(id: "sandra-home-message", source: .messages, title: "Home", body: "Personal update", author: "+351968816710", participants: ["+351968816710"], timestamp: Date(timeIntervalSince1970: 1_750_000_000), url: nil, threadID: "sandra"),
            IndexedRecord(id: "sandra-work-message", source: .messages, title: "Work", body: "Project update", author: "+351932845129", participants: ["+351932845129"], timestamp: Date(timeIntervalSince1970: 1_750_000_001), url: nil, threadID: "sandra"),
            IndexedRecord(id: "unrelated-message", source: .messages, title: "Other", body: "Other update", author: "+351911111111", participants: ["+351911111111"], timestamp: Date(timeIntervalSince1970: 1_750_000_002), url: nil, threadID: "other")
        ])

        let planner = QueryPlanner(identityResolver: IdentityResolver(identities: [
            ContactIdentity(id: "sandra-a", displayName: "Sandra Martins", aliases: [], handles: ["968 816 710"]),
            ContactIdentity(id: "sandra-b", displayName: "Sandra Martins", aliases: [], handles: ["+351 932 845 129"])
        ]))
        let plan = planner.plan("What did Sandra Martins tell me?")
        let hits = try await index.search(plan: plan, limit: 10)
        XCTAssertEqual(Set(hits.map(\.record.id)), ["sandra-home-message", "sandra-work-message"])
    }

    func testResolvedPersonTokensAreNotTopicKeywords() {
        let planner = QueryPlanner(identityResolver: IdentityResolver(identities: [
            ContactIdentity(id: "sandra", displayName: "Sandra Martins", aliases: [], handles: ["sandra@example.test"])
        ]))
        let plan = planner.plan("What did Sandra Martins tell me about the shipment today?")
        XCTAssertFalse(plan.keywords.contains("sandra"))
        XCTAssertFalse(plan.keywords.contains("martins"))
        XCTAssertTrue(plan.keywords.contains("shipment"))
        XCTAssertTrue(plan.isConstrainedByDate)
    }

    func testEmailBackedPersonRetrievalRemainsSupported() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-digest-email-identity-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let index = SQLiteIndex(databaseURL: databaseURL)
        try await index.merge(source: .messages, with: [
            IndexedRecord(id: "email-message", source: .messages, title: "Update", body: "The shipment is ready.", author: "rui@example.test", participants: ["rui@example.test"], timestamp: Date(timeIntervalSince1970: 1_750_000_000), url: nil, threadID: nil)
        ])
        let planner = QueryPlanner(identityResolver: IdentityResolver(identities: [
            ContactIdentity(id: "rui", displayName: "Rui Almeida", aliases: ["Rui"], handles: ["rui@example.test"])
        ]))
        let hits = try await index.search(plan: planner.plan("What did Rui Almeida tell me?"), limit: 10)
        XCTAssertEqual(hits.map(\.record.id), ["email-message"])
    }

    func testExactToldWordingResolvesDuplicatePersonAndTodayMessages() async throws {
        let reference = ISO8601DateFormatter().date(from: "2026-08-21T12:00:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-digest-told-identity-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let index = SQLiteIndex(databaseURL: databaseURL)
        let todayMorning = calendar.date(byAdding: .hour, value: -2, to: reference)!
        try await index.merge(source: .messages, with: [
            IndexedRecord(id: "sandra-today", source: .messages, title: "Update", body: "The shipment is ready.", author: "+351932845129", participants: ["+351932845129"], timestamp: todayMorning, url: nil, threadID: nil),
            IndexedRecord(id: "unrelated-today", source: .messages, title: "Other", body: "Unrelated contact.", author: "+351911111111", participants: ["+351911111111"], timestamp: todayMorning, url: nil, threadID: nil)
        ])
        let identities = [
            ContactIdentity(id: "sandra-a", displayName: "Sandra Martins", aliases: [], handles: ["+351 932 845 129"]),
            ContactIdentity(id: "sandra-b", displayName: "Sandra Martins", aliases: [], handles: ["968 816 710"])
        ]
        let planner = QueryPlanner(dateParser: DatePhraseParser(calendar: calendar, now: { reference }), identityResolver: IdentityResolver(identities: identities))
        let plan = planner.plan("what did Sandra Martins told me today?", referenceDate: reference)

        XCTAssertEqual(plan.ambiguity, [])
        XCTAssertEqual(plan.constraints.person, "Sandra Martins")
        XCTAssertTrue(plan.constraints.personTerms.contains("+351 932 845 129"))
        XCTAssertTrue(plan.constraints.personTerms.contains("968 816 710"))
        XCTAssertTrue(plan.keywords.isEmpty)
        XCTAssertEqual(plan.constraints.startDate, calendar.startOfDay(for: reference))
        XCTAssertEqual(plan.constraints.endDate, calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: reference)))
        let hits = try await index.search(plan: plan, limit: 10)
        XCTAssertEqual(hits.map(\.record.id), ["sandra-today"])

        let saidPlan = planner.plan("what did Sandra Martins said yesterday?", referenceDate: reference)
        XCTAssertEqual(saidPlan.constraints.person, "Sandra Martins")
    }

    func testNumericEmailUsernamesDoNotUsePhoneSuffixMatching() {
        XCTAssertFalse(IdentityResolver.matchesSearchTerm("12345678@example.com", against: "987654321@example.com"))
        XCTAssertTrue(IdentityResolver.matchesSearchTerm("Rui@example.com", against: "rui@example.com"))
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

    func testGoDeeperFollowUpInheritsPriorPersonDateSourceAndTopic() {
        let reference = ISO8601DateFormatter().date(from: "2026-08-21T12:00:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let startOfDay = calendar.startOfDay(for: reference)
        let prior = QueryPlan(
            originalQuestion: "What did Sandra say about the shipment today?",
            keywords: ["shipment"],
            constraints: SearchConstraints(person: "Sandra Martins", personTerms: ["+351 932 845 129"], startDate: startOfDay, endDate: startOfDay.addingTimeInterval(86_400), sources: [.messages]),
            needsConversationExpansion: false,
            ambiguity: []
        )
        let plan = QueryPlanner().plan("Go deeper on this", context: prior, referenceDate: reference)
        XCTAssertTrue(QueryPlanner.looksLikeFollowUp("Go deeper on this"))
        XCTAssertEqual(plan.constraints, prior.constraints)
        XCTAssertEqual(plan.keywords, prior.keywords)
        XCTAssertEqual(plan.constraints.person, "Sandra Martins")
    }

    func testTypedFollowUpRetainsPriorRafaelaEvidenceWhenFreshTopicSearchIsEmpty() {
        let reference = ISO8601DateFormatter().date(from: "2026-08-21T12:00:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: reference))!
        let prior = QueryPlan(
            originalQuestion: "what did Rafaela said yesterday?",
            keywords: [],
            constraints: SearchConstraints(person: "Rafaela Martins", personTerms: ["rafaela@example.test"], startDate: yesterday, endDate: calendar.date(byAdding: .day, value: 1, to: yesterday), sources: [.messages]),
            needsConversationExpansion: false,
            ambiguity: []
        )
        let plan = QueryPlanner().plan("were their old people?", context: prior, referenceDate: reference)
        XCTAssertTrue(plan.continuesConversation)
        XCTAssertEqual(plan.constraints, prior.constraints)
        XCTAssertTrue(plan.keywords.contains("old"))
        XCTAssertTrue(plan.keywords.contains("people"))

        let oldEvidence = SearchHit(record: IndexedRecord(id: "rafaela-old", source: .messages, title: "Conversation", body: "A private fixture", author: "rafaela@example.test", participants: ["rafaela@example.test"], timestamp: yesterday.addingTimeInterval(3_600), url: nil, threadID: nil), score: 1)
        let retained = AppStore.mergeConversationEvidence(retrieved: [], prior: [oldEvidence], constraints: plan.constraints)
        XCTAssertEqual(retained.map(\.id), ["rafaela-old"])

        let changedDate = QueryPlanner().plan("were their old people today?", context: prior, referenceDate: reference)
        XCTAssertTrue(changedDate.constraints.startDate! > prior.constraints.startDate!)
        XCTAssertTrue(AppStore.mergeConversationEvidence(retrieved: [], prior: [oldEvidence], constraints: changedDate.constraints).isEmpty)
    }

    func testScreenshotContactSequenceKeepsGrammarAndDateTyposOutOfFTS() {
        let reference = ISO8601DateFormatter().date(from: "2026-09-16T12:00:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let planner = QueryPlanner(
            dateParser: DatePhraseParser(calendar: calendar, now: { reference }),
            identityResolver: IdentityResolver(identities: [
                ContactIdentity(id: "rafaela", displayName: "Rafaela Martins", aliases: ["Rafaela"], handles: ["rafaela@example.test"]),
                ContactIdentity(id: "cachinhos", displayName: "Cachinhos", aliases: [], handles: ["cachinhos@example.test"])
            ])
        )

        let first = planner.plan("what did Rafaea asked me today?", referenceDate: reference)
        let second = planner.plan("what did Rafaela said today?", context: first, referenceDate: reference)
        let third = planner.plan("What did Cachinhos said toyda?", context: second, referenceDate: reference)

        XCTAssertEqual(first.constraints.person, "Rafaela Martins")
        XCTAssertTrue(first.keywords.isEmpty)
        XCTAssertEqual(second.constraints.person, "Rafaela Martins")
        XCTAssertTrue(second.keywords.isEmpty)
        XCTAssertEqual(third.constraints.person, "Cachinhos")
        XCTAssertTrue(third.keywords.isEmpty)
        XCTAssertEqual(third.constraints.startDate, calendar.startOfDay(for: reference))
        XCTAssertEqual(third.constraints.endDate, calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: reference)))
    }

    func testScreenshotContactSequenceRetrievesRafaelaAndKeepsCachinhosTodayEmpty() async throws {
        let reference = ISO8601DateFormatter().date(from: "2026-09-16T12:00:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.startOfDay(for: reference).addingTimeInterval(3_600)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("local-digest-query-regression-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
        }

        let index = SQLiteIndex(databaseURL: url)
        try await index.merge(source: .messages, with: [
            IndexedRecord(id: "rafaela-today", source: .messages, title: "Rafaela", body: "Shipment is ready", author: "rafaela@example.test", participants: ["rafaela@example.test"], timestamp: today, url: nil, threadID: nil),
            IndexedRecord(id: "cachinhos-yesterday", source: .messages, title: "Cachinhos", body: "Earlier update", author: "cachinhos@example.test", participants: ["cachinhos@example.test"], timestamp: yesterday, url: nil, threadID: nil),
            IndexedRecord(id: "unrelated-today", source: .messages, title: "Other", body: "Unrelated update", author: "other@example.test", participants: ["other@example.test"], timestamp: today, url: nil, threadID: nil)
        ])
        let planner = QueryPlanner(
            dateParser: DatePhraseParser(calendar: calendar, now: { reference }),
            identityResolver: IdentityResolver(identities: [
                ContactIdentity(id: "rafaela", displayName: "Rafaela Martins", aliases: ["Rafaela"], handles: ["rafaela@example.test"]),
                ContactIdentity(id: "cachinhos", displayName: "Cachinhos", aliases: [], handles: ["cachinhos@example.test"])
            ])
        )
        let scope = SearchScope(selectedSources: [.messages])

        let first = planner.plan("what did Rafaea asked me today?", scope: scope, referenceDate: reference)
        let firstHits = try await index.search(plan: first)
        XCTAssertEqual(firstHits.map(\.record.id), ["rafaela-today"])

        let second = planner.plan("what did Rafaela said today?", scope: scope, context: first, referenceDate: reference)
        let secondHits = try await index.search(plan: second)
        XCTAssertEqual(secondHits.map(\.record.id), ["rafaela-today"])

        let third = planner.plan("What did Cachinhos said toyda?", scope: scope, context: second, referenceDate: reference)
        let thirdHits = try await index.search(plan: third)
        XCTAssertTrue(thirdHits.isEmpty)

        let latest = planner.plan("latest messages from Cachinhos", scope: scope, referenceDate: reference)
        let latestHits = try await index.search(plan: latest)
        XCTAssertEqual(latestHits.map(\.record.id), ["cachinhos-yesterday"])
    }

    func testAskedRemainsSearchableWhenItIsAnExplicitTopic() {
        let planner = QueryPlanner(
            identityResolver: IdentityResolver(identities: [
                ContactIdentity(id: "rafaela", displayName: "Rafaela Martins", aliases: ["Rafaela"], handles: ["rafaela@example.test"])
            ])
        )

        let mention = planner.plan("find messages mentioning asked", scope: SearchScope(selectedSources: [.messages]))
        let semanticTopic = planner.plan("What did Rafaela say about being asked today?")

        XCTAssertTrue(mention.keywords.contains("asked"))
        XCTAssertTrue(semanticTopic.keywords.contains("asked"))
        XCTAssertTrue(semanticTopic.keywords.contains("being"))
    }

    func testChangedPersonDoesNotInheritPriorTopicButSamePersonCan() {
        let reference = ISO8601DateFormatter().date(from: "2026-09-16T12:00:00Z")!
        let planner = QueryPlanner(
            dateParser: DatePhraseParser(now: { reference }),
            identityResolver: IdentityResolver(identities: [
                ContactIdentity(id: "rafaela", displayName: "Rafaela Martins", aliases: ["Rafaela"], handles: ["rafaela@example.test"]),
                ContactIdentity(id: "cachinhos", displayName: "Cachinhos", aliases: [], handles: ["cachinhos@example.test"])
            ])
        )
        let prior = planner.plan("what did Rafaela say about shipment yesterday?", referenceDate: reference)

        let samePerson = planner.plan("what did Rafaela say today?", context: prior, referenceDate: reference)
        let changedPerson = planner.plan("what did Cachinhos say today?", context: prior, referenceDate: reference)

        XCTAssertEqual(samePerson.keywords, ["shipment"])
        XCTAssertEqual(changedPerson.constraints.person, "Cachinhos")
        XCTAssertTrue(changedPerson.keywords.isEmpty)

        for continuation in ["And Cachinhos?", "What about Cachinhos?"] {
            let continued = planner.plan(continuation, context: prior, referenceDate: reference)
            XCTAssertEqual(continued.constraints.person, "Cachinhos", continuation)
            XCTAssertEqual(continued.keywords, ["shipment"], continuation)
            XCTAssertTrue(continued.continuesConversation, continuation)
        }
    }

    func testTemporalTypoMapsToTodayForFreshAndContextPlansAcrossSources() {
        let reference = ISO8601DateFormatter().date(from: "2026-09-16T12:00:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let planner = QueryPlanner(
            dateParser: DatePhraseParser(calendar: calendar, now: { reference }),
            identityResolver: IdentityResolver(identities: [
                ContactIdentity(id: "rafaela", displayName: "Rafaela Martins", aliases: ["Rafaela"], handles: ["rafaela@example.test"])
            ])
        )
        let yesterday = planner.plan("what did Rafaela say yesterday?", scope: SearchScope(selectedSources: [.messages]), referenceDate: reference)
        let freshMessages = planner.plan("what did Rafaela say toyda?", scope: SearchScope(selectedSources: [.messages]), referenceDate: reference)
        let contextMessages = planner.plan("what did Rafaela say toyda?", scope: SearchScope(selectedSources: [.messages]), context: yesterday, referenceDate: reference)
        let freshMail = planner.plan("what is in mail toyda?", scope: SearchScope(selectedSources: [.mail]), referenceDate: reference)

        let todayStart = calendar.startOfDay(for: reference)
        let todayEnd = calendar.date(byAdding: .day, value: 1, to: todayStart)
        for plan in [freshMessages, contextMessages, freshMail] {
            XCTAssertEqual(plan.constraints.startDate, todayStart)
            XCTAssertEqual(plan.constraints.endDate, todayEnd)
            XCTAssertTrue(plan.keywords.isEmpty)
        }
        XCTAssertEqual(contextMessages.constraints.sources, [.messages])
        XCTAssertEqual(freshMail.constraints.sources, [.mail])
    }

    func testExplicitMailRefinesConversationWithoutDroppingPersonOrDate() {
        let reference = ISO8601DateFormatter().date(from: "2026-08-21T12:00:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: reference))!
        let prior = QueryPlan(
            originalQuestion: "what did Rafaela say yesterday?",
            keywords: ["shipment"],
            constraints: SearchConstraints(person: "Rafaela Martins", personTerms: ["rafaela@example.test"], startDate: yesterday, endDate: yesterday.addingTimeInterval(86_400), sources: [.messages]),
            needsConversationExpansion: false,
            ambiguity: []
        )
        let plan = QueryPlanner().plan("was that in Mail?", context: prior, referenceDate: reference)
        XCTAssertTrue(plan.continuesConversation)
        XCTAssertEqual(plan.constraints.sources, [.mail])
        XCTAssertEqual(plan.constraints.person, prior.constraints.person)
        XCTAssertEqual(plan.constraints.personTerms, prior.constraints.personTerms)
        XCTAssertEqual(plan.constraints.startDate, prior.constraints.startDate)
        XCTAssertEqual(plan.constraints.endDate, prior.constraints.endDate)
        XCTAssertTrue(plan.keywords.contains("shipment"))

        let messages = SearchHit(record: IndexedRecord(id: "rafaela-message", source: .messages, title: "Old", body: "fixture", author: "rafaela@example.test", participants: [], timestamp: yesterday.addingTimeInterval(100), url: nil, threadID: nil), score: 1)
        let mail = SearchHit(record: IndexedRecord(id: "rafaela-mail", source: .mail, title: "Mail", body: "fixture", author: "rafaela@example.test", participants: [], timestamp: yesterday.addingTimeInterval(200), url: nil, threadID: nil), score: 1)
        let retained = AppStore.mergeConversationEvidence(retrieved: [mail], prior: [messages], constraints: plan.constraints)
        XCTAssertEqual(retained.map(\.id), ["rafaela-mail"])
    }

    func testCumulativeConversationEvidenceRetainsThreeTurnsAndResetsOnNewConversation() async {
        let constraints = SearchConstraints(person: nil, personTerms: [], sources: [.messages])
        func hit(_ id: String) -> SearchHit {
            SearchHit(record: IndexedRecord(id: id, source: .messages, title: id, body: "fixture", author: nil, participants: [], timestamp: Date(timeIntervalSince1970: 100), url: nil, threadID: nil), score: 1)
        }
        var cumulative: [SearchHit] = []
        cumulative = AppStore.mergeConversationEvidence(retrieved: [hit("one")], prior: cumulative, constraints: constraints, limit: 96)
        cumulative = AppStore.mergeConversationEvidence(retrieved: [hit("two")], prior: cumulative, constraints: constraints, limit: 96)
        cumulative = AppStore.mergeConversationEvidence(retrieved: [hit("three")], prior: cumulative, constraints: constraints, limit: 96)
        XCTAssertEqual(Set(cumulative.map(\.id)), Set(["one", "two", "three"]))

        let store = await MainActor.run {
            AppStore(indexCoordinator: IndexCoordinator(index: SQLiteIndex(databaseURL: URL(fileURLWithPath: "/tmp/nonexistent-localdigest-test.sqlite")), adapters: []))
        }
        let initialEvidenceCount = await MainActor.run { store.conversationEvidenceCount }
        XCTAssertEqual(initialEvidenceCount, 0)
        await store.startNewConversation()
        let resetEvidenceCount = await MainActor.run { store.conversationEvidenceCount }
        XCTAssertEqual(resetEvidenceCount, 0)
    }

    func testDeeperEvidencePrioritizesUnseenRecordsAndRemainsBounded() {
        let records = (0..<30).map { index in
            SearchHit(record: IndexedRecord(id: "record-\(index)", source: .messages, title: "Message \(index)", body: "Evidence", author: nil, participants: [], timestamp: Date(timeIntervalSince1970: TimeInterval(index)), url: nil, threadID: nil), score: Double(30 - index))
        }
        let selected = AppStore.selectDeeperEvidence(retrieved: records, priorIDs: Set(["record-0", "record-1", "record-2"]), limit: 10)
        XCTAssertEqual(selected.count, 10)
        XCTAssertEqual(selected.prefix(3).map(\.id), ["record-3", "record-4", "record-5"])
        XCTAssertEqual(selected.last?.id, "record-2")
    }

    func testDeeperPromptLabelsEarlierAnswerAsContextNotEvidence() {
        let prompt = PromptBuilder.makePrompt(
            question: "Go deeper on this",
            evidence: [],
            previousAnswer: "The earlier answer said the shipment was delayed.",
            requireNewDetails: true
        )
        XCTAssertTrue(prompt.contains("Earlier answer (conversation context only; NOT evidence)"))
        XCTAssertTrue(prompt.contains("newly supported details"))
        XCTAssertTrue(prompt.contains("if no additional supported detail exists, say that plainly"))
    }

    @MainActor
    func testGoDeeperUnavailableWithoutCompletedEvidence() async {
        let store = AppStore(indexCoordinator: IndexCoordinator(index: SQLiteIndex(databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent("empty-go-deeper-\(UUID().uuidString).sqlite"))))
        XCTAssertFalse(store.canGoDeeper)
        store.answerText = "A completed answer"
        XCTAssertFalse(store.canGoDeeper)
        store.answer = Answer(text: store.answerText, citations: [], provider: .appleLocal)
        store.hits = [SearchHit(record: IndexedRecord(id: "deeper-seed", source: .messages, title: "Seed", body: "Evidence", author: nil, participants: [], timestamp: Date(), url: nil, threadID: nil), score: 1)]
        XCTAssertTrue(store.canGoDeeper)
        await store.goDeeper()
        XCTAssertFalse(store.isDeeperFollowUpPending)
    }

    @MainActor
    func testComposerLabelsSwitchOnlyForActiveConversationAndResetOnNewConversation() async {
        let store = AppStore(indexCoordinator: IndexCoordinator(index: SQLiteIndex(databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent("composer-state-\(UUID().uuidString).sqlite"))))
        XCTAssertEqual(store.composerTitle, "Ask Local Digest")
        XCTAssertEqual(store.composerSubmitTitle, "Ask")
        XCTAssertTrue(store.composerPlaceholder.contains("What did Rui"))

        store.conversationTurns = [ConversationTurn(question: "First", answer: "Answer", citations: [], provider: .appleLocal)]
        XCTAssertEqual(store.composerTitle, "Ask a follow-up")
        XCTAssertEqual(store.composerSubmitTitle, "Follow up")
        XCTAssertEqual(store.composerPlaceholder, "Ask another question about this answer…")

        await store.startNewConversation()
        XCTAssertEqual(store.composerTitle, "Ask Local Digest")
        XCTAssertEqual(store.composerSubmitTitle, "Ask")
        XCTAssertNil(store.questionForSaving)
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

    func testConversationExpansionPreservesNewestFirstCapAndConstraints() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-digest-conversation-ordering-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-shm")
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-wal")
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let reference = ISO8601DateFormatter().date(from: "2026-08-28T12:00:00Z")!
        let today = calendar.startOfDay(for: reference)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let handle = "cachinhos@example.test"
        let todayRecords = (0..<6).map { index in
            IndexedRecord(
                id: "cachinhos-today-\(index)", source: .messages, title: "Cachinhos \(index)", body: "Shipment update \(index)",
                author: handle, participants: [handle], timestamp: today.addingTimeInterval(Double(index + 1) * 3_600), url: nil, threadID: "cachinhos-thread"
            )
        }
        let records = todayRecords + [
            IndexedRecord(id: "other-today", source: .messages, title: "Other", body: "Shipment update", author: "other@example.test", participants: ["other@example.test"], timestamp: today.addingTimeInterval(28_800), url: nil, threadID: "cachinhos-thread"),
            IndexedRecord(id: "cachinhos-yesterday", source: .messages, title: "Cachinhos old", body: "Older shipment update", author: handle, participants: [handle], timestamp: yesterday.addingTimeInterval(82_800), url: nil, threadID: "cachinhos-thread")
        ]
        let index = SQLiteIndex(databaseURL: databaseURL)
        try await index.merge(source: .messages, with: records)

        let planner = QueryPlanner(
            dateParser: DatePhraseParser(calendar: calendar, now: { reference }),
            identityResolver: IdentityResolver(identities: [
                ContactIdentity(id: "cachinhos", displayName: "Cachinhos", aliases: [], handles: [handle])
            ])
        )
        let scope = SearchScope(selectedSources: [.messages])
        let latest = planner.plan("latest messages from Cachinhos", scope: scope, referenceDate: reference)
        XCTAssertEqual(latest.ordering, .newestFirst)
        XCTAssertEqual(latest.requestedResultCount, 5)
        XCTAssertTrue(latest.needsConversationExpansion)
        let latestRetrieved = try await index.search(plan: latest, limit: latest.requestedResultCount ?? 60)
        XCTAssertEqual(latestRetrieved.map(\.record.id), [
            "cachinhos-today-5", "cachinhos-today-4", "cachinhos-today-3", "cachinhos-today-2", "cachinhos-today-1", "cachinhos-today-0", "cachinhos-yesterday"
        ])
        XCTAssertTrue(latestRetrieved.allSatisfy { $0.record.author == handle })
        let latestHits = Array(latestRetrieved.prefix(latest.requestedResultCount ?? latestRetrieved.count))
        XCTAssertEqual(latestHits.map(\.record.id), [
            "cachinhos-today-5", "cachinhos-today-4", "cachinhos-today-3", "cachinhos-today-2", "cachinhos-today-1"
        ])
        XCTAssertTrue(latestHits.allSatisfy { $0.record.author == handle })

        let todayLatest = planner.plan("latest messages from Cachinhos today", scope: scope, referenceDate: reference)
        XCTAssertEqual(todayLatest.constraints.startDate, today)
        XCTAssertEqual(todayLatest.constraints.endDate, calendar.date(byAdding: .day, value: 1, to: today))
        let todayRetrieved = try await index.search(plan: todayLatest, limit: todayLatest.requestedResultCount ?? 60)
        XCTAssertEqual(todayRetrieved.map(\.record.id), [
            "cachinhos-today-5", "cachinhos-today-4", "cachinhos-today-3", "cachinhos-today-2", "cachinhos-today-1", "cachinhos-today-0"
        ])
        XCTAssertTrue(todayRetrieved.allSatisfy { $0.record.author == handle && $0.record.timestamp >= today && $0.record.timestamp < todayLatest.constraints.endDate! })
        let todayHits = Array(todayRetrieved.prefix(todayLatest.requestedResultCount ?? todayRetrieved.count))
        XCTAssertEqual(todayHits.map(\.record.id), [
            "cachinhos-today-5", "cachinhos-today-4", "cachinhos-today-3", "cachinhos-today-2", "cachinhos-today-1"
        ])
        XCTAssertTrue(todayHits.allSatisfy { $0.record.timestamp >= today && $0.record.timestamp < todayLatest.constraints.endDate! })
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

    func testMailIncrementalMailboxEnumerationAvoidsFullMailboxCounts() {
        let incremental = MailSourceAdapter.mailboxReferencesScript()
        XCTAssertTrue(incremental.contains("every mailbox of a"))
        XCTAssertFalse(incremental.contains("count of messages"))
        let full = MailSourceAdapter.recordsScript(accountIndex: 1, mailboxIndex: 1, range: 1...50)
        XCTAssertTrue(full.contains("count of messages"))
        XCTAssertEqual(MailSourceAdapter.mailboxProgressLabel(index: 2, total: 5), "Mail mailbox 2 of 5")
    }

    func testMailIncrementalLookbackKeepsMinimumAndExtendsOlderCursor() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let recent = SourceCursor(watermark: now.addingTimeInterval(-86_400), rawWatermark: nil, rowID: nil, stableID: nil)
        let older = SourceCursor(watermark: now.addingTimeInterval(-20 * 86_400), rawWatermark: nil, rowID: nil, stableID: nil)
        XCTAssertEqual(MailSourceAdapter.lookbackSeconds(for: recent, now: now), 7 * 86_400)
        XCTAssertEqual(MailSourceAdapter.lookbackSeconds(for: older, now: now), 27 * 86_400)
    }

    func testMailIncrementalMergePreservesReceivedDatesForRelativeDateQueries() async throws {
        let databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("local-digest-mail-dates-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL); try? FileManager.default.removeItem(atPath: databaseURL.path + "-shm"); try? FileManager.default.removeItem(atPath: databaseURL.path + "-wal") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let reference = ISO8601DateFormatter().date(from: "2026-08-21T12:00:00Z")!
        let today = calendar.startOfDay(for: reference).addingTimeInterval(3_600)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let old = calendar.date(byAdding: .day, value: -30, to: today)!
        let records = [today, yesterday, old].enumerated().map { index, date in
            IndexedRecord(id: "mail-date-\(index)", source: .mail, title: "Mail \(index)", body: "received body \(index)", author: "sender@example.test", participants: [], timestamp: date, url: nil, threadID: nil)
        }
        let index = SQLiteIndex(databaseURL: databaseURL)
        try await index.merge(source: .mail, with: records)
        let planner = QueryPlanner(dateParser: DatePhraseParser(calendar: calendar, now: { reference }))
        let scope = SearchScope(selectedSources: [.mail])
        let todayHits = try await index.search(plan: planner.plan("today", scope: scope, referenceDate: reference))
        let yesterdayHits = try await index.search(plan: planner.plan("yesterday", scope: scope, referenceDate: reference))
        XCTAssertEqual(todayHits.map(\.record.id), ["mail-date-0"])
        XCTAssertEqual(yesterdayHits.map(\.record.id), ["mail-date-1"])
    }

    func testMailRecencyPhrasesPlanNewestFirstAndStripOperators() {
        let planner = QueryPlanner()
        let cases: [(String, Int)] = [
            ("latest 5 emails", 5),
            ("newest 3 emails", 3),
            ("5 most recent emails", 5),
            ("last 4 emails", 4),
            ("Summarize 5 emails today", 5)
        ]
        for (question, count) in cases {
            let plan = planner.plan(question)
            XCTAssertEqual(plan.ordering, .newestFirst, question)
            XCTAssertEqual(plan.requestedResultCount, count, question)
            XCTAssertFalse(plan.keywords.contains { ["latest", "newest", "recent", "most", "last"].contains($0) }, question)
        }
        XCTAssertEqual(planner.plan("latest 999 emails").requestedResultCount, 50)
        XCTAssertEqual(planner.plan("emails about shipment").ordering, .relevance)
        let topic = planner.plan("find a note about the latest release")
        XCTAssertEqual(topic.ordering, .relevance)
        XCTAssertTrue(topic.keywords.contains("latest"))
        XCTAssertTrue(topic.keywords.contains("release"))
        let latestPerson = planner.plan("latest messages from Rui")
        XCTAssertEqual(latestPerson.ordering, .newestFirst)
        XCTAssertEqual(latestPerson.requestedResultCount, 5)
        XCTAssertTrue(latestPerson.keywords.contains("rui"))
        let latestTopic = planner.plan("newest note about project")
        XCTAssertEqual(latestTopic.ordering, .newestFirst)
        XCTAssertEqual(latestTopic.requestedResultCount, 1)
        XCTAssertTrue(latestTopic.keywords.contains("project"))
        let latestPluralTopic = planner.plan("latest notes about project")
        XCTAssertEqual(latestPluralTopic.ordering, .newestFirst)
        XCTAssertEqual(latestPluralTopic.requestedResultCount, 5)
        XCTAssertTrue(latestPluralTopic.keywords.contains("project"))
    }

    func testKnownContactBeforeRecencyResolvesTypoPossessiveAndSourceForms() {
        let planner = QueryPlanner(identityResolver: IdentityResolver(identities: [
            ContactIdentity(id: "cachinhos-a", displayName: "Cachinhos", aliases: ["Cachi"], handles: ["+351 910 000 001"]),
            ContactIdentity(id: "cachinhos-b", displayName: " Cachinhos ", aliases: [], handles: ["+351 910 000 002"]),
            ContactIdentity(id: "rui", displayName: "Rui Almeida", aliases: ["Rui"], handles: ["rui@example.test"]),
            ContactIdentity(id: "apple", displayName: "Apple", aliases: [], handles: ["apple@example.test"])
        ]))

        for question in [
            "Summarize Cachinhos latest messages",
            "Summarize Cachinhos latests messages",
            "Cachinhos latest messages",
            "latest messages from Cachinhos",
            "latest messages with Cachinhos",
            "latest messages for Cachinhos"
        ] {
            let plan = planner.plan(question, scope: SearchScope(selectedSources: [.messages]))
            XCTAssertEqual(plan.constraints.sources, [.messages], question)
            XCTAssertEqual(plan.constraints.person, "Cachinhos", question)
            XCTAssertEqual(plan.ordering, .newestFirst, question)
            XCTAssertEqual(plan.requestedResultCount, 5, question)
            XCTAssertFalse(plan.keywords.contains("cachinhos"), question)
            XCTAssertFalse(plan.keywords.contains("latests"), question)
            XCTAssertFalse(plan.keywords.contains("latest"), question)
        }

        let possessive = planner.plan("Show Rui's latest 3 messages", scope: SearchScope(selectedSources: [.messages]))
        XCTAssertEqual(possessive.constraints.person, "Rui Almeida")
        XCTAssertTrue(possessive.constraints.personTerms.contains("rui@example.test"))
        XCTAssertEqual(possessive.ordering, .newestFirst)
        XCTAssertEqual(possessive.requestedResultCount, 3)

        let mail = planner.plan("Cachinhos latest emails", scope: SearchScope(selectedSources: [.mail]))
        XCTAssertEqual(mail.constraints.sources, [.mail])
        XCTAssertEqual(mail.constraints.person, "Cachinhos")
        XCTAssertEqual(mail.ordering, .newestFirst)
        XCTAssertEqual(mail.requestedResultCount, 5)
        XCTAssertTrue(mail.keywords.isEmpty)
    }

    func testRecencyAndPersonSlotsDoNotCaptureTopicPhrases() {
        let planner = QueryPlanner(identityResolver: IdentityResolver(identities: [
            ContactIdentity(id: "apple", displayName: "Apple", aliases: [], handles: ["apple@example.test"])
        ]))

        let communicationTopic = planner.plan("messages about Apple", scope: SearchScope(selectedSources: [.messages]))
        XCTAssertNil(communicationTopic.constraints.person)
        XCTAssertTrue(communicationTopic.keywords.contains("apple"))
        XCTAssertEqual(communicationTopic.ordering, .relevance)

        let literalTopic = planner.plan("latest release messages", scope: SearchScope(selectedSources: [.messages]))
        XCTAssertNil(literalTopic.constraints.person)
        XCTAssertTrue(literalTopic.keywords.contains("latest"))
        XCTAssertTrue(literalTopic.keywords.contains("release"))
        XCTAssertEqual(literalTopic.ordering, .relevance)

        let typoTopic = planner.plan("latests release messages", scope: SearchScope(selectedSources: [.messages]))
        XCTAssertTrue(typoTopic.keywords.contains("latests"))
        XCTAssertTrue(typoTopic.keywords.contains("release"))
        XCTAssertEqual(typoTopic.ordering, .relevance)

        let noteTopic = planner.plan("find a note about latest release")
        XCTAssertTrue(noteTopic.keywords.contains("latest"))
        XCTAssertTrue(noteTopic.keywords.contains("release"))
        XCTAssertEqual(noteTopic.ordering, .relevance)

        let timeframe = planner.plan("summarize 5 messages for today", scope: SearchScope(selectedSources: [.messages]))
        XCTAssertNil(timeframe.constraints.person)
        XCTAssertNotNil(timeframe.constraints.startDate)
        XCTAssertNotNil(timeframe.constraints.endDate)
    }

    func testExplicitPreSourceContactOverridesPriorPersonAndKeepsCompatibleContext() {
        let reference = ISO8601DateFormatter().date(from: "2026-08-28T12:00:00Z")!
        let start = reference.addingTimeInterval(-86_400)
        let end = reference
        let planner = QueryPlanner(identityResolver: IdentityResolver(identities: [
            ContactIdentity(id: "rui", displayName: "Rui Almeida", aliases: ["Rui"], handles: ["rui@example.test"]),
            ContactIdentity(id: "cachinhos", displayName: "Cachinhos", aliases: [], handles: ["cachinhos@example.test"])
        ]))
        let prior = QueryPlan(
            originalQuestion: "What did Rui say yesterday?",
            keywords: ["shipment"],
            constraints: SearchConstraints(person: "Rui Almeida", personTerms: ["rui@example.test"], startDate: start, endDate: end, sources: [.messages]),
            needsConversationExpansion: true,
            ambiguity: [],
            ordering: .newestFirst,
            requestedResultCount: 5
        )

        let plan = planner.plan("Cachinhos latests messages", context: prior, referenceDate: reference)
        XCTAssertEqual(plan.constraints.sources, [.messages])
        XCTAssertEqual(plan.constraints.person, "Cachinhos")
        XCTAssertEqual(plan.constraints.personTerms, ["Cachinhos", "cachinhos@example.test"])
        XCTAssertEqual(plan.constraints.startDate, start)
        XCTAssertEqual(plan.constraints.endDate, end)
        XCTAssertEqual(plan.ordering, .newestFirst)
        XCTAssertEqual(plan.requestedResultCount, 5)
    }

    func testDuplicateContactHandlesRetrieveNewestMessagesForTypoQuery() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-digest-cachinhos-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-shm")
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-wal")
        }

        let reference = ISO8601DateFormatter().date(from: "2026-08-28T12:00:00Z")!
        let firstHandle = "+351 910 000 001"
        let secondHandle = "+351 910 000 002"
        let records = (0..<6).map { offset in
            let handle = offset.isMultiple(of: 2) ? firstHandle : secondHandle
            return IndexedRecord(
                id: "cachinhos-message-\(offset)", source: .messages, title: "Message \(offset)", body: "Synthetic fixture \(offset)",
                author: handle, participants: [handle], timestamp: reference.addingTimeInterval(TimeInterval(offset * 60)), url: nil, threadID: nil
            )
        } + [IndexedRecord(
            id: "unrelated-message", source: .messages, title: "Unrelated", body: "Synthetic fixture", author: "+351 911 000 000",
            participants: ["+351 911 000 000"], timestamp: reference.addingTimeInterval(10_000), url: nil, threadID: nil
        )]
        let index = SQLiteIndex(databaseURL: databaseURL)
        try await index.merge(source: .messages, with: records)

        let planner = QueryPlanner(identityResolver: IdentityResolver(identities: [
            ContactIdentity(id: "cachinhos-a", displayName: "Cachinhos", aliases: [], handles: [firstHandle]),
            ContactIdentity(id: "cachinhos-b", displayName: "Cachinhos", aliases: [], handles: [secondHandle])
        ]))
        let plan = planner.plan("Summarize Cachinhos latests messages", scope: SearchScope(selectedSources: [.messages]), referenceDate: reference)
        XCTAssertEqual(plan.constraints.person, "Cachinhos")
        XCTAssertEqual(Set(plan.constraints.personTerms), Set(["Cachinhos", firstHandle, secondHandle]))
        XCTAssertEqual(plan.ordering, .newestFirst)
        XCTAssertEqual(plan.requestedResultCount, 5)
        XCTAssertTrue(plan.keywords.isEmpty)

        let hits = try await index.search(plan: plan, limit: plan.requestedResultCount ?? 60)
        XCTAssertEqual(hits.map(\.record.id), [
            "cachinhos-message-5", "cachinhos-message-4", "cachinhos-message-3", "cachinhos-message-2", "cachinhos-message-1"
        ])
    }

    func testKnownContactsBeforeSourceDoNotRequireRecencyAndSourceTyposStayStructural() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let reference = ISO8601DateFormatter().date(from: "2026-08-28T12:00:00Z")!
        let identities = [
            ContactIdentity(id: "cachinhos-a", displayName: "Cachinhos", aliases: ["Cachi"], handles: ["+351 910 000 001"]),
            ContactIdentity(id: "cachinhos-b", displayName: " Cachinhos ", aliases: [], handles: ["+351 910 000 002"]),
            ContactIdentity(id: "rui", displayName: "Rui Almeida", aliases: ["Rui"], handles: ["rui@example.test"]),
            ContactIdentity(id: "apple", displayName: "Apple", aliases: [], handles: ["apple@example.test"])
        ]
        let planner = QueryPlanner(
            dateParser: DatePhraseParser(calendar: calendar, now: { reference }),
            identityResolver: IdentityResolver(identities: identities)
        )
        let week = calendar.dateInterval(of: .weekOfYear, for: reference)!

        for question in [
            "Summarize Cachinhos messages of this week",
            "Summarize Cachinos messas of this week"
        ] {
            let plan = planner.plan(question, scope: SearchScope(selectedSources: [.messages]), referenceDate: reference)
            XCTAssertEqual(plan.constraints.sources, [.messages], question)
            XCTAssertEqual(plan.constraints.person, "Cachinhos", question)
            XCTAssertEqual(Set(plan.constraints.personTerms), Set(["Cachinhos", "Cachi", "+351 910 000 001", "+351 910 000 002"]), question)
            XCTAssertEqual(plan.constraints.startDate, week.start, question)
            XCTAssertEqual(plan.constraints.endDate, week.end, question)
            XCTAssertEqual(plan.ordering, .newestFirst, question)
            XCTAssertEqual(plan.requestedResultCount, 5, question)
            XCTAssertTrue(plan.keywords.isEmpty, question)
            XCTAssertTrue(plan.needsConversationExpansion, question)
        }

        let latest = planner.plan("latest message from Cachinhos", scope: SearchScope(selectedSources: [.messages]), referenceDate: reference)
        XCTAssertEqual(latest.constraints.sources, [.messages])
        XCTAssertEqual(latest.constraints.person, "Cachinhos")
        XCTAssertEqual(latest.ordering, .newestFirst)
        XCTAssertEqual(latest.requestedResultCount, 1)
        XCTAssertTrue(latest.keywords.isEmpty)

        let noDate = planner.plan("Summarize Cachinhos messages", scope: SearchScope(selectedSources: [.messages]))
        XCTAssertEqual(noDate.constraints.person, "Cachinhos")
        XCTAssertEqual(noDate.ordering, .newestFirst)
        XCTAssertEqual(noDate.requestedResultCount, 5)
        XCTAssertTrue(noDate.keywords.isEmpty)

        let otherContact = planner.plan("Summarize 3 Rui emails of this week", scope: SearchScope(selectedSources: [.mail]), referenceDate: reference)
        XCTAssertEqual(otherContact.constraints.sources, [.mail])
        XCTAssertEqual(otherContact.constraints.person, "Rui Almeida")
        XCTAssertEqual(otherContact.constraints.personTerms, ["Rui Almeida", "Rui", "rui@example.test"])
        XCTAssertEqual(otherContact.constraints.startDate, week.start)
        XCTAssertEqual(otherContact.constraints.endDate, week.end)
        XCTAssertEqual(otherContact.ordering, .newestFirst)
        XCTAssertEqual(otherContact.requestedResultCount, 3)
        XCTAssertTrue(otherContact.keywords.isEmpty)

        let projectTopic = planner.plan("summarize project messages this week", scope: SearchScope(selectedSources: [.messages]), referenceDate: reference)
        XCTAssertNil(projectTopic.constraints.person)
        XCTAssertTrue(projectTopic.keywords.contains("project"))
        XCTAssertFalse(projectTopic.keywords.contains("messages"))

        let appleTopic = planner.plan("Apple release messages", scope: SearchScope(selectedSources: [.messages]))
        XCTAssertNil(appleTopic.constraints.person)
        XCTAssertEqual(appleTopic.ordering, .relevance)
        XCTAssertTrue(appleTopic.keywords.contains("apple"))
        XCTAssertTrue(appleTopic.keywords.contains("release"))

        let ambiguousPlanner = QueryPlanner(identityResolver: IdentityResolver(identities: [
            ContactIdentity(id: "cachinhos", displayName: "Cachinhos", aliases: [], handles: ["cachinhos-a@example.test"]),
            ContactIdentity(id: "cachinas", displayName: "Cachinas", aliases: [], handles: ["cachinas@example.test"])
        ]))
        let ambiguous = ambiguousPlanner.plan("Summarize Cachinos messages")
        XCTAssertEqual(Set(ambiguous.ambiguity), Set(["Cachinhos", "Cachinas"]))
    }

    func testFuzzyContactAndSourceRetrieveOnlyCurrentWeekMessages() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let reference = ISO8601DateFormatter().date(from: "2026-08-28T12:00:00Z")!
        let week = calendar.dateInterval(of: .weekOfYear, for: reference)!
        let firstHandle = "+351 910 000 001"
        let secondHandle = "+351 910 000 002"
        let records = [
            IndexedRecord(id: "inside-old", source: .messages, title: "Inside old", body: "Synthetic fixture", author: "+351910000001", participants: ["+351910000001"], timestamp: week.start.addingTimeInterval(3_600), url: nil, threadID: nil),
            IndexedRecord(id: "inside-new", source: .messages, title: "Inside new", body: "Synthetic fixture", author: "351 910 000 002", participants: ["351 910 000 002"], timestamp: week.start.addingTimeInterval(86_400), url: nil, threadID: nil),
            IndexedRecord(id: "inside-latest", source: .messages, title: "Inside latest", body: "Synthetic fixture", author: firstHandle, participants: [firstHandle], timestamp: reference, url: nil, threadID: nil),
            IndexedRecord(id: "outside-before", source: .messages, title: "Outside before", body: "Synthetic fixture", author: firstHandle, participants: [firstHandle], timestamp: week.start.addingTimeInterval(-1), url: nil, threadID: nil),
            IndexedRecord(id: "outside-after", source: .messages, title: "Outside after", body: "Synthetic fixture", author: secondHandle, participants: [secondHandle], timestamp: week.end, url: nil, threadID: nil),
            IndexedRecord(id: "unrelated", source: .messages, title: "Unrelated", body: "Synthetic fixture", author: "+351 911 000 000", participants: ["+351 911 000 000"], timestamp: reference.addingTimeInterval(60), url: nil, threadID: nil)
        ]
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-digest-cachinos-current-week-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-shm")
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-wal")
        }
        let index = SQLiteIndex(databaseURL: databaseURL)
        try await index.merge(source: .messages, with: records)
        let planner = QueryPlanner(
            dateParser: DatePhraseParser(calendar: calendar, now: { reference }),
            identityResolver: IdentityResolver(identities: [
                ContactIdentity(id: "cachinhos-a", displayName: "Cachinhos", aliases: [], handles: [firstHandle]),
                ContactIdentity(id: "cachinhos-b", displayName: " Cachinhos ", aliases: [], handles: [secondHandle])
            ])
        )
        let plan = planner.plan("Summarize Cachinos messas of this week", scope: SearchScope(selectedSources: [.messages]), referenceDate: reference)
        XCTAssertEqual(plan.constraints.sources, [.messages])
        XCTAssertEqual(plan.constraints.person, "Cachinhos")
        XCTAssertEqual(plan.constraints.startDate, week.start)
        XCTAssertEqual(plan.constraints.endDate, week.end)
        XCTAssertTrue(plan.keywords.isEmpty)
        let hits = try await index.search(plan: plan, limit: plan.requestedResultCount ?? 60)
        XCTAssertEqual(hits.map(\.record.id), ["inside-latest", "inside-new", "inside-old"])
        XCTAssertTrue(hits.allSatisfy { $0.record.source == .messages })
        XCTAssertTrue(hits.allSatisfy { $0.record.timestamp >= week.start && $0.record.timestamp < week.end })
    }

    func testMailRecencySearchReturnsNewestRequestedRecordsInsideFixedDate() async throws {
        let databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("local-digest-mail-recency-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL); try? FileManager.default.removeItem(atPath: databaseURL.path + "-shm"); try? FileManager.default.removeItem(atPath: databaseURL.path + "-wal") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let reference = ISO8601DateFormatter().date(from: "2026-08-21T12:00:00Z")!
        let day = calendar.startOfDay(for: reference)
        let dates = [1, 2, 3, 4, 5, 6].map { day.addingTimeInterval(Double($0) * 3_600) }
            + [day.addingTimeInterval(-3_600), day.addingTimeInterval(86_400 + 3_600)]
        let records = dates.enumerated().map { index, date in
            IndexedRecord(id: "recency-\(index)", source: .mail, title: "Mail \(index)", body: index == 5 ? "shipment" : "ordinary", author: "sender@example.test", participants: [], timestamp: date, url: nil, threadID: nil)
        }
        let index = SQLiteIndex(databaseURL: databaseURL)
        try await index.merge(source: .mail, with: records)
        let planner = QueryPlanner(dateParser: DatePhraseParser(calendar: calendar, now: { reference }))
        let plan = planner.plan("Summarize 5 emails today", scope: SearchScope(selectedSources: [.mail]), referenceDate: reference)
        XCTAssertEqual(plan.constraints.startDate, day)
        XCTAssertEqual(plan.constraints.endDate, day.addingTimeInterval(86_400))
        XCTAssertEqual(plan.ordering, .newestFirst)
        let hits = try await index.search(plan: plan, limit: plan.requestedResultCount ?? 60)
        XCTAssertEqual(hits.map(\.record.id), ["recency-5", "recency-4", "recency-3", "recency-2", "recency-1"])

        let topicPlan = planner.plan("latest 2 emails about shipment", scope: SearchScope(selectedSources: [.mail]), referenceDate: reference)
        let topicHits = try await index.search(plan: topicPlan, limit: topicPlan.requestedResultCount ?? 60)
        XCTAssertEqual(topicHits.map(\.record.id), ["recency-5"])
    }

    func testNewestFirstPromptStatesOrdering() {
        let prompt = PromptBuilder.makePrompt(question: "latest 2 emails", evidence: [], ordering: .newestFirst)
        XCTAssertTrue(prompt.contains("ordered newest first"))
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("use every supplied record"))
    }

    func testRecencyConversationFollowUpYesterdayKeepsMailOrderingAndCount() async throws {
        let databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("local-digest-mail-recency-follow-up-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL); try? FileManager.default.removeItem(atPath: databaseURL.path + "-shm"); try? FileManager.default.removeItem(atPath: databaseURL.path + "-wal") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let reference = ISO8601DateFormatter().date(from: "2026-08-22T12:00:00Z")!
        let today = calendar.startOfDay(for: reference)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let records = [
            IndexedRecord(id: "follow-up-aug22", source: .mail, title: "Aug 22", body: "mail", author: nil, participants: [], timestamp: today.addingTimeInterval(3_600), url: nil, threadID: nil),
            IndexedRecord(id: "follow-up-aug21-a", source: .mail, title: "Aug 21 A", body: "mail", author: nil, participants: [], timestamp: yesterday.addingTimeInterval(7_200), url: nil, threadID: nil),
            IndexedRecord(id: "follow-up-aug21-b", source: .mail, title: "Aug 21 B", body: "mail", author: nil, participants: [], timestamp: yesterday.addingTimeInterval(3_600), url: nil, threadID: nil),
            IndexedRecord(id: "follow-up-aug20", source: .mail, title: "Aug 20", body: "mail", author: nil, participants: [], timestamp: yesterday.addingTimeInterval(-3_600), url: nil, threadID: nil)
        ]
        let index = SQLiteIndex(databaseURL: databaseURL)
        try await index.merge(source: .mail, with: records)
        let planner = QueryPlanner(dateParser: DatePhraseParser(calendar: calendar, now: { reference }))
        let scope = SearchScope(selectedSources: [.mail])
        let first = planner.plan("latest 5 emails", scope: scope, referenceDate: reference)
        XCTAssertEqual(first.ordering, .newestFirst)
        XCTAssertEqual(first.requestedResultCount, 5)
        let followUp = planner.plan("yesterday", scope: scope, context: first, referenceDate: reference)
        XCTAssertTrue(followUp.continuesConversation)
        XCTAssertEqual(followUp.constraints.sources, [.mail])
        XCTAssertEqual(followUp.ordering, .newestFirst)
        XCTAssertEqual(followUp.requestedResultCount, 5)
        XCTAssertFalse(followUp.keywords.contains { ["latest", "newest", "recent", "most", "last"].contains($0) })
        let followUpHits = try await index.search(plan: followUp, limit: followUp.requestedResultCount ?? 60)
        XCTAssertEqual(followUpHits.map(\.record.id), ["follow-up-aug21-a", "follow-up-aug21-b"])

        let standalone = planner.plan("Summarize 5 emails yesterday", scope: scope, referenceDate: reference)
        let standaloneHits = try await index.search(plan: standalone, limit: standalone.requestedResultCount ?? 60)
        XCTAssertEqual(standaloneHits.map(\.record.id), ["follow-up-aug21-a", "follow-up-aug21-b"])
    }

    func testChronologicalOrderingGeneralizesAcrossDatedSources() async throws {
        let databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("local-digest-all-source-ordering-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL); try? FileManager.default.removeItem(atPath: databaseURL.path + "-shm"); try? FileManager.default.removeItem(atPath: databaseURL.path + "-wal") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let reference = ISO8601DateFormatter().date(from: "2026-08-22T12:00:00Z")!
        let day = calendar.startOfDay(for: reference)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: day)!
        func record(_ id: String, _ source: SourceKind, _ timestamp: Date) -> IndexedRecord {
            IndexedRecord(id: id, source: source, title: id, body: "fixture", author: nil, participants: [], timestamp: timestamp, url: nil, threadID: nil)
        }
        let records = [
            record("message-old", .messages, yesterday), record("message-new", .messages, yesterday.addingTimeInterval(3_600)),
            record("note-old", .notes, yesterday), record("note-new", .notes, yesterday.addingTimeInterval(7_200)), record("note-newest", .notes, yesterday.addingTimeInterval(10_800)),
            record("event-past", .calendar, day.addingTimeInterval(-3_600)), record("event-near", .calendar, reference.addingTimeInterval(3_600)), record("event-later", .calendar, reference.addingTimeInterval(7_200)),
            record("reminder-undated", .reminders, .distantPast), record("reminder-past", .reminders, reference.addingTimeInterval(-3_600)), record("reminder-near", .reminders, reference.addingTimeInterval(1_800)), record("reminder-later", .reminders, reference.addingTimeInterval(5_400))
        ]
        let index = SQLiteIndex(databaseURL: databaseURL)
        for source in SourceKind.allCases where source != .contacts {
            let subset = records.filter { $0.source == source }
            if !subset.isEmpty { try await index.merge(source: source, with: subset) }
        }
        let planner = QueryPlanner(dateParser: DatePhraseParser(calendar: calendar, now: { reference }))
        let messages = planner.plan("latest 3 messages", scope: SearchScope(selectedSources: [.messages]), referenceDate: reference)
        let messageIDs = try await index.search(plan: messages, limit: 3).map(\.record.id)
        XCTAssertEqual(messageIDs, ["message-new", "message-old"])
        let notes = planner.plan("latest 2 notes", scope: SearchScope(selectedSources: [.notes]), referenceDate: reference)
        let noteIDs = try await index.search(plan: notes, limit: 2).map(\.record.id)
        XCTAssertEqual(noteIDs, ["note-newest", "note-new"])
        let events = planner.plan("next 3 calendar events", scope: SearchScope(selectedSources: [.calendar]), referenceDate: reference)
        XCTAssertEqual(events.ordering, .upcomingFirst)
        XCTAssertEqual(events.requestedResultCount, 3)
        let eventIDs = try await index.search(plan: events, limit: 3).map(\.record.id)
        XCTAssertEqual(eventIDs, ["event-near", "event-later"])
        let reminders = planner.plan("upcoming 3 reminders", scope: SearchScope(selectedSources: [.reminders]), referenceDate: reference)
        let reminderIDs = try await index.search(plan: reminders, limit: 3).map(\.record.id)
        XCTAssertEqual(reminderIDs, ["reminder-near", "reminder-later"])

        for (question, source) in [("messages today", SourceKind.messages), ("notes yesterday", .notes), ("calendar today", .calendar), ("reminders today", .reminders)] {
            let plan = planner.plan(question, scope: SearchScope(selectedSources: [source]), referenceDate: reference)
            XCTAssertNotNil(plan.constraints.startDate, question)
            XCTAssertNotNil(plan.constraints.endDate, question)
        }
        let contacts = planner.plan("latest 2 contacts", scope: SearchScope(selectedSources: [.contacts]), referenceDate: reference)
        XCTAssertEqual(contacts.ordering, .relevance)
        XCTAssertNil(contacts.requestedResultCount)
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

    func testMailboxDetailProgressDoesNotAlterCommittedRecordCount() async throws {
        let databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("local-digest-mail-progress-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL); try? FileManager.default.removeItem(atPath: databaseURL.path + "-shm"); try? FileManager.default.removeItem(atPath: databaseURL.path + "-wal") }
        let recorder = MailProgressRecorder()
        let record = IndexedRecord(id: "mail-progress", source: .mail, title: "Progress", body: "body", author: "sender@example.test", participants: [], timestamp: Date(), url: nil, threadID: nil)
        let coordinator = IndexCoordinator(index: SQLiteIndex(databaseURL: databaseURL), adapters: [MailProgressAdapter(record: record)])
        _ = await coordinator.indexAll(mode: .incremental, progress: { source, count, total in
            Task { await recorder.numeric(source: source, count: count, total: total) }
        }, detail: { source, message in
            Task { await recorder.detail(source: source, message: message) }
        })
        let details = await recorder.details()
        let numeric = await recorder.numericValues()
        XCTAssertTrue(details.contains("Mail mailbox 1 of 1"))
        XCTAssertTrue(details.contains { $0 == nil })
        XCTAssertEqual(numeric, ["mail:0:-1", "mail:1:1"])
        let statuses = await coordinator.statuses()
        XCTAssertEqual(statuses.first(where: { $0.source == .mail })?.indexedCount, 1)
    }

    func testMailboxDetailProgressEndsWithFailureMessage() async {
        let recorder = MailProgressRecorder()
        let coordinator = IndexCoordinator(index: SQLiteIndex(databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent("local-digest-mail-progress-failure-\(UUID().uuidString).sqlite")), adapters: [MailProgressAdapter(record: nil, shouldFail: true)])
        _ = await coordinator.indexAll(mode: .incremental, progress: { source, count, total in
            Task { await recorder.numeric(source: source, count: count, total: total) }
        }, detail: { source, message in
            Task { await recorder.detail(source: source, message: message) }
        })
        let details = await recorder.details()
        let numeric = await recorder.numericValues()
        let deliveredDetails = details.compactMap { $0 }
        XCTAssertEqual(deliveredDetails.first, "Mail mailbox 1 of 1")
        XCTAssertTrue((deliveredDetails.last ?? "").contains("Mail:"))
        XCTAssertEqual(numeric, ["mail:0:-1", "mail:-1:-1"])
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

    func testHybridInterpreterFillsNaturalLanguageSlotsAndComputesRelativeDateLocally() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let reference = ISO8601DateFormatter().date(from: "2026-08-28T12:00:00Z")!
        let week = calendar.dateInterval(of: .weekOfYear, for: reference)!
        let calls = IntentInterpreterProbe(
            result: StructuredQueryIntent(
                sources: [.messages],
                personPhrase: "Cachinhos",
                topicPhrase: "shipment",
                timeframePhrase: "this week",
                requestedCount: 5,
                ordering: .newestFirst
            )
        )
        let planner = QueryPlanner(
            dateParser: DatePhraseParser(calendar: calendar, now: { reference }),
            identityResolver: IdentityResolver(identities: [
                ContactIdentity(id: "cachinhos", displayName: "Cachinhos", aliases: [], handles: ["cachinhos@example.test"])
            ])
        )
        let plan = await HybridQueryPlanner(planner: planner, interpreter: calls)
            .plan("Catch me up on Cachinhos this week", scope: SearchScope(selectedSources: [.messages]), referenceDate: reference)

        let capturedQuestions = await calls.questions()
        XCTAssertEqual(capturedQuestions, ["Catch me up on Cachinhos this week"])
        XCTAssertEqual(plan.constraints.sources, [.messages])
        XCTAssertEqual(plan.constraints.person, "Cachinhos")
        XCTAssertEqual(plan.constraints.startDate, week.start)
        XCTAssertEqual(plan.constraints.endDate, week.end)
        XCTAssertEqual(plan.keywords, ["shipment"])
        XCTAssertEqual(plan.ordering, .newestFirst)
        XCTAssertEqual(plan.requestedResultCount, 5)
        XCTAssertTrue(plan.needsConversationExpansion)
    }

    func testHybridPronounFollowUpInheritsPersonButUsesModelOrdering() async {
        let reference = ISO8601DateFormatter().date(from: "2026-08-28T12:00:00Z")!
        let planner = QueryPlanner(
            dateParser: DatePhraseParser(now: { reference }),
            identityResolver: IdentityResolver(identities: [
                ContactIdentity(id: "rui", displayName: "Rui Almeida", aliases: ["Rui"], handles: ["rui@example.test"]),
                ContactIdentity(id: "marta", displayName: "Marta Silva", aliases: ["Marta"], handles: ["marta@example.test"])
            ])
        )
        let prior = planner.plan("What did Rui tell me this week?", referenceDate: reference)
        let interpreter = IntentInterpreterProbe(result: StructuredQueryIntent(
            sources: [.messages], personPhrase: "she", requestedCount: 5, ordering: .newestFirst, continuesConversation: true
        ))

        let plan = await HybridQueryPlanner(planner: planner, interpreter: interpreter)
            .plan("What has she sent recently?", context: prior, referenceDate: reference)

        let interpreterCalls = await interpreter.callCount()
        XCTAssertEqual(interpreterCalls, 1)
        XCTAssertEqual(plan.constraints.person, "Rui Almeida")
        XCTAssertEqual(plan.constraints.sources, [.messages])
        XCTAssertEqual(plan.constraints.startDate, prior.constraints.startDate)
        XCTAssertEqual(plan.ordering, .newestFirst)
        XCTAssertEqual(plan.requestedResultCount, 5)
        XCTAssertFalse(plan.keywords.contains("she"))
        XCTAssertFalse(plan.keywords.contains("has"))
    }

    func testNaturalModelOrderingOverridesInheritedContextButNotCurrentRecency() async {
        let reference = ISO8601DateFormatter().date(from: "2026-08-28T12:00:00Z")!
        let planner = QueryPlanner(
            dateParser: DatePhraseParser(now: { reference }),
            identityResolver: IdentityResolver(identities: [
                ContactIdentity(id: "rui", displayName: "Rui Almeida", aliases: ["Rui"], handles: ["rui@example.test"]),
                ContactIdentity(id: "marta", displayName: "Marta Silva", aliases: ["Marta"], handles: ["marta@example.test"])
            ])
        )
        let prior = planner.plan("latest 5 messages from Rui", scope: SearchScope(selectedSources: [.messages]), referenceDate: reference)
        let interpreter = IntentInterpreterProbe(result: StructuredQueryIntent(topicPhrase: "amounts", requestedCount: 2, ordering: .upcomingFirst))
        let inheritedOverride = await HybridQueryPlanner(planner: planner, interpreter: interpreter)
            .plan("How much did she ask?", scope: SearchScope(selectedSources: [.messages]), context: prior, referenceDate: reference)
        XCTAssertEqual(inheritedOverride.ordering, .upcomingFirst)
        XCTAssertEqual(inheritedOverride.requestedResultCount, 2)

        let currentRecency = await HybridQueryPlanner(planner: planner, interpreter: interpreter)
            .plan("latest 3 messages from Rui", scope: SearchScope(selectedSources: [.messages]), context: prior, referenceDate: reference)
        XCTAssertEqual(currentRecency.ordering, .newestFirst)
        XCTAssertEqual(currentRecency.requestedResultCount, 3)

        let knownReplacement = IntentInterpreterProbe(result: StructuredQueryIntent(personPhrase: "Marta", topicPhrase: "amounts"))
        let knownPlan = await HybridQueryPlanner(planner: planner, interpreter: knownReplacement)
            .plan("How much was requested by Marta today?", scope: SearchScope(selectedSources: [.messages]), context: prior, referenceDate: reference)
        XCTAssertEqual(knownPlan.constraints.person, "Marta Silva")
        XCTAssertFalse(knownPlan.hasUnresolvedPersonPhrase)

        let unknownReplacement = IntentInterpreterProbe(result: StructuredQueryIntent(personPhrase: "Unknown Person", topicPhrase: "amounts"))
        let unknownPlan = await HybridQueryPlanner(planner: planner, interpreter: unknownReplacement)
            .plan("How much was requested by Unknown Person today?", scope: SearchScope(selectedSources: [.messages]), context: prior, referenceDate: reference)
        XCTAssertNil(unknownPlan.constraints.person)
        XCTAssertTrue(unknownPlan.hasUnresolvedPersonPhrase)
        XCTAssertEqual(unknownPlan.retrievalPolicy, .literalKeywords)
    }

    func testHybridScopeIsHardBoundaryWhenModelSuggestsDifferentSource() async {
        let interpreter = IntentInterpreterProbe(result: StructuredQueryIntent(sources: [.messages], topicPhrase: "shipment"))
        let planner = QueryPlanner()
        let plan = await HybridQueryPlanner(planner: planner, interpreter: interpreter)
            .plan("Tell me about the shipment", scope: SearchScope(selectedSources: [.mail]))

        let interpreterCalls = await interpreter.callCount()
        XCTAssertEqual(interpreterCalls, 1)
        XCTAssertTrue(plan.constraints.sources.isEmpty)
        XCTAssertEqual(plan.intent, .inherited)
        XCTAssertTrue(plan.keywords.contains("shipment"))
    }

    func testLiteralLookupBypassesInterpreter() async {
        let reference = ISO8601DateFormatter().date(from: "2026-08-28T12:00:00Z")!
        let interpreter = IntentInterpreterProbe(result: StructuredQueryIntent(sources: [.mail], personPhrase: "Other Person"))
        let planner = QueryPlanner(
            dateParser: DatePhraseParser(now: { reference }),
            identityResolver: IdentityResolver(identities: [
                ContactIdentity(id: "c", displayName: "Cachinhos", aliases: [], handles: ["c@example.test"])
            ])
        )
        let plan = await HybridQueryPlanner(planner: planner, interpreter: interpreter)
            .plan("Find messages mentioning shipment from Cachinhos", scope: SearchScope(selectedSources: [.messages]), referenceDate: reference)

        let interpreterCalls = await interpreter.callCount()
        XCTAssertEqual(interpreterCalls, 0)
        XCTAssertEqual(plan.constraints.person, "Cachinhos")
        XCTAssertEqual(plan.constraints.sources, [.messages])
    }

    func testInterpreterFailureAndCopiedPersonValidationFallBackDeterministically() async {
        let reference = ISO8601DateFormatter().date(from: "2026-08-28T12:00:00Z")!
        let planner = QueryPlanner(dateParser: DatePhraseParser(now: { reference }))
        let throwing = IntentInterpreterProbe(error: true)
        let failedPlan = await HybridQueryPlanner(planner: planner, interpreter: throwing)
            .plan("A free-form shipment question", referenceDate: reference)
        let throwingCalls = await throwing.callCount()
        XCTAssertEqual(throwingCalls, 1)
        XCTAssertEqual(failedPlan, planner.plan("A free-form shipment question", referenceDate: reference))

        let inventedPerson = IntentInterpreterProbe(result: StructuredQueryIntent(personPhrase: "Not in this question"))
        let inventedPlan = await HybridQueryPlanner(planner: planner, interpreter: inventedPerson)
            .plan("A free-form shipment question", referenceDate: reference)
        let inventedPersonCalls = await inventedPerson.callCount()
        XCTAssertEqual(inventedPersonCalls, 1)
        XCTAssertEqual(inventedPlan, planner.plan("A free-form shipment question", referenceDate: reference))
    }

    func testNaturalAskTimeoutIsConfigurableAndFailureKeepsScopedFallback() async {
        let reference = ISO8601DateFormatter().date(from: "2026-09-16T12:00:00Z")!
        let calendar = Calendar(identifier: .gregorian)
        let planner = QueryPlanner(
            dateParser: DatePhraseParser(calendar: calendar, now: { reference }),
            identityResolver: IdentityResolver(identities: [
                ContactIdentity(id: "marta", displayName: "Marta Silva", aliases: ["Marta"], handles: ["marta@example.test"])
            ])
        )
        let interpreted = StructuredQueryIntent(topicPhrase: "amounts")
        let delayed = DelayedIntentInterpreterProbe(delayNanoseconds: 850_000_000, result: interpreted)
        let accepted = await HybridQueryPlanner(
            planner: planner,
            interpreter: delayed,
            interpretationTimeoutNanoseconds: 1_500_000_000
        ).plan("How much did Marta ask today?", scope: SearchScope(selectedSources: [.messages]), referenceDate: reference)
        XCTAssertEqual(accepted.constraints.person, "Marta Silva")
        XCTAssertEqual(accepted.retrievalPolicy, .scopedSemanticEvidence)
        XCTAssertTrue(accepted.keywords.contains("amounts"))
        let delayedCalls = await delayed.callCount()
        XCTAssertEqual(delayedCalls, 1)

        let fastTimeout = DelayedIntentInterpreterProbe(delayNanoseconds: 250_000_000, result: interpreted)
        let started = Date()
        let timedOut = await HybridQueryPlanner(
            planner: planner,
            interpreter: fastTimeout,
            interpretationTimeoutNanoseconds: 20_000_000
        ).plan("How much did Marta ask today?", scope: SearchScope(selectedSources: [.messages]), referenceDate: reference)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(timedOut, planner.plan("How much did Marta ask today?", scope: SearchScope(selectedSources: [.messages]), referenceDate: reference))
        XCTAssertLessThan(elapsed, 0.5)
        let fastCalls = await fastTimeout.callCount()
        XCTAssertEqual(fastCalls, 1)

        let throwing = IntentInterpreterProbe(error: true)
        let failed = await HybridQueryPlanner(planner: planner, interpreter: throwing)
            .plan("How much did Marta ask today?", scope: SearchScope(selectedSources: [.messages]), referenceDate: reference)
        XCTAssertEqual(failed, timedOut)
    }

    func testUnknownAskPersonCannotBroadenToUnrelatedTopicalEvidenceIncludingModelMerge() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("local-digest-unknown-person-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
        }
        let reference = ISO8601DateFormatter().date(from: "2026-09-16T12:00:00Z")!
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: reference).addingTimeInterval(3_600)
        let record = IndexedRecord(
            id: "known-money", source: .messages, title: "Pagamento", body: "The money transfer is confirmed.",
            author: "marta@example.test", participants: ["marta@example.test"], timestamp: today,
            url: nil, threadID: nil
        )
        let literalRecord = IndexedRecord(
            id: "literal-unknown", source: .messages, title: "Reference", body: "Unknown Person confirmed the money transfer.",
            author: "marta@example.test", participants: ["marta@example.test"], timestamp: today,
            url: nil, threadID: nil
        )
        let index = SQLiteIndex(databaseURL: url)
        try await index.merge(source: .messages, with: [record, literalRecord])
        let planner = QueryPlanner(
            dateParser: DatePhraseParser(calendar: calendar, now: { reference }),
            identityResolver: IdentityResolver(identities: [
                ContactIdentity(id: "marta", displayName: "Marta Silva", aliases: ["Marta"], handles: ["marta@example.test"])
            ])
        )

        let unknownPlan = planner.plan(
            "What did Unknown Person ask today?",
            scope: SearchScope(selectedSources: [.messages]),
            referenceDate: reference
        )
        XCTAssertTrue(unknownPlan.hasUnresolvedPersonPhrase)
        XCTAssertEqual(unknownPlan.retrievalPolicy, .literalKeywords)
        let unknownHits = try await index.search(plan: unknownPlan)
        XCTAssertTrue(unknownHits.isEmpty)

        // The model may identify a person phrase that the deterministic pass
        // did not see ("by <person>"). The merged policy must become safe too.
        let modelInterpreter = IntentInterpreterProbe(result: StructuredQueryIntent(personPhrase: "Unknown Person", topicPhrase: "money"))
        let modelPlan = await HybridQueryPlanner(planner: planner, interpreter: modelInterpreter)
            .plan(
                "How much was requested by Unknown Person today?",
                scope: SearchScope(selectedSources: [.messages]),
                referenceDate: reference
            )
        XCTAssertTrue(modelPlan.hasUnresolvedPersonPhrase)
        XCTAssertEqual(modelPlan.retrievalPolicy, .literalKeywords)
        let modelHits = try await index.search(plan: modelPlan)
        XCTAssertTrue(modelHits.isEmpty)

        // Search is a literal surface, so an unknown name remains searchable
        // when the indexed text itself contains it.
        let literalSearch = planner.plan(
            "find messages containing Unknown Person",
            scope: SearchScope(selectedSources: [.messages]),
            referenceDate: reference,
            surface: .search
        )
        let literalHits = try await index.search(plan: literalSearch)
        XCTAssertTrue(literalHits.contains { $0.record.id == "literal-unknown" })
    }

    func testStructuredIntentRejectsIdentifiersTimestampsAndQuerySyntax() {
        XCTAssertNotNil(StructuredQueryIntent(
            modelSources: "messages",
            modelPersonPhrase: "Cachinhos",
            modelTopicPhrase: "shipment",
            modelTimeframePhrase: "2026-08-28",
            modelRequestedCount: 5,
            modelOrdering: "newest",
            continuesConversation: false
        ))
        XCTAssertNil(StructuredQueryIntent(
            modelSources: "messages",
            modelPersonPhrase: "cachinhos@example.test",
            modelTopicPhrase: "shipment",
            modelTimeframePhrase: "today",
            modelRequestedCount: 0,
            modelOrdering: "",
            continuesConversation: false
        ))
        XCTAssertNil(StructuredQueryIntent(
            modelSources: "messages",
            modelPersonPhrase: "Cachinhos",
            modelTopicPhrase: "SELECT * FROM records",
            modelTimeframePhrase: "today",
            modelRequestedCount: 0,
            modelOrdering: "",
            continuesConversation: false
        ))
        XCTAssertNil(StructuredQueryIntent(
            modelSources: "messages",
            modelPersonPhrase: "Cachinhos",
            modelTopicPhrase: "shipment",
            modelTimeframePhrase: "2026-08-28T12:00:00Z",
            modelRequestedCount: 0,
            modelOrdering: "",
            continuesConversation: false
        ))
    }

    func testHybridModelSourceContractSupportsEveryIndexedSource() async {
        let reference = ISO8601DateFormatter().date(from: "2026-08-28T12:00:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let week = calendar.dateInterval(of: .weekOfYear, for: reference)!
        for source in SourceKind.allCases {
            let interpreter = IntentInterpreterProbe(result: StructuredQueryIntent(sources: [source], timeframePhrase: "this week"))
            let planner = QueryPlanner(dateParser: DatePhraseParser(calendar: calendar, now: { reference }))
            let plan = await HybridQueryPlanner(planner: planner, interpreter: interpreter)
                .plan("A free-form request", scope: SearchScope(selectedSources: [source]), referenceDate: reference)
            XCTAssertEqual(plan.constraints.sources, [source], source.rawValue)
            XCTAssertEqual(plan.constraints.startDate, week.start, source.rawValue)
            XCTAssertEqual(plan.constraints.endDate, week.end, source.rawValue)
        }
    }

    @MainActor
    func testEmptyRetrievalDoesNotInvokeAnswerStreamer() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("local-digest-empty-answer-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
        }
        let contact = IndexedRecord(
            id: "contact-rui-empty", source: .contacts, title: "Rui Almeida", body: "Rui Almeida\nrui@example.test",
            author: "Rui Almeida", participants: ["rui@example.test"], timestamp: .distantPast,
            url: nil, threadID: nil
        )
        let index = SQLiteIndex(databaseURL: url)
        try? await index.merge(source: .contacts, with: [contact])
        let interpreter = IntentInterpreterProbe(result: StructuredQueryIntent(sources: [.messages], personPhrase: "Rui", requestedCount: 5, ordering: .newestFirst))
        let streamer = AnswerStreamerProbe()
        let coordinator = IndexCoordinator(index: index, adapters: [])
        let store = AppStore(indexCoordinator: coordinator, intentInterpreter: interpreter, answerStreamer: streamer)
        store.question = "Anything new from Rui?"
        await store.ask()

        let streamerCalls = await streamer.callCount()
        XCTAssertEqual(streamerCalls, 0)
        XCTAssertTrue(store.hits.isEmpty)
        XCTAssertEqual(store.answerText, "The indexed evidence did not contain a matching record.")
        XCTAssertNotNil(store.answer)
    }

    @MainActor
    func testAskNaturalAmountQuestionUsesScopedSemanticEvidenceAndPronounFollowUps() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("local-digest-natural-amount-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
        }
        let calendar = Calendar.autoupdatingCurrent
        let reference = Date()
        let today = calendar.startOfDay(for: reference).addingTimeInterval(3_600)
        let handle = "marta@example.test"
        let contact = IndexedRecord(id: "contact-marta", source: .contacts, title: "Marta Silva", body: "Marta", author: "Marta Silva", participants: [handle], timestamp: .distantPast, url: nil, threadID: nil)
        let message = IndexedRecord(
            id: "marta-amount", source: .messages, title: "Atualização", body: "Ela pediu 4,20 € para a encomenda e depois mais 2 €. Eu enviei 7 €.",
            author: handle, participants: [handle], timestamp: today, url: nil, threadID: "marta-thread"
        )
        let mixedLanguageMessage = IndexedRecord(
            id: "marta-amount-english", source: .messages, title: "Follow-up", body: "The amounts were confirmed afterward.",
            author: handle, participants: [handle], timestamp: today.addingTimeInterval(1_200), url: nil, threadID: "marta-thread"
        )
        let index = SQLiteIndex(databaseURL: url)
        try await index.merge(source: .contacts, with: [contact])
        try await index.merge(source: .messages, with: [message, mixedLanguageMessage])
        let coordinator = IndexCoordinator(index: index, adapters: [])
        let interpreter = IntentInterpreterProbe(result: StructuredQueryIntent(topicPhrase: "amounts"))
        let streamer = EvidenceAnswerStreamerProbe()
        let store = AppStore(indexCoordinator: coordinator, intentInterpreter: interpreter, answerStreamer: streamer)

        store.question = "how much money did Marta asked me today"
        await store.ask()
        XCTAssertEqual(Set(store.hits.map(\.record.id)), ["marta-amount", "marta-amount-english"])
        XCTAssertEqual(store.answerText, "Evidence received")
        let firstInterpreterCalls = await interpreter.callCount()
        XCTAssertEqual(firstInterpreterCalls, 1)

        store.question = "How much did Unknown Person ask today?"
        await store.ask()
        XCTAssertTrue(store.hits.isEmpty)
        XCTAssertEqual(store.answerText, "I couldn't match that person to an indexed contact. Try a full name or handle.")

        store.question = "How much did she need?"
        await store.ask()
        XCTAssertEqual(Set(store.hits.map(\.record.id)), ["marta-amount", "marta-amount-english"])
        store.question = "And how much did I actually send her?"
        await store.ask()
        XCTAssertEqual(Set(store.hits.map(\.record.id)), ["marta-amount", "marta-amount-english"])

        let evidence = await streamer.evidenceByCall()
        XCTAssertEqual(evidence.count, 3)
        XCTAssertTrue(evidence.allSatisfy { Set($0.map(\.record.id)) == ["marta-amount", "marta-amount-english"] })
        let questions = await streamer.questions()
        XCTAssertEqual(questions, [
            "how much money did Marta asked me today",
            "How much did she need?",
            "And how much did I actually send her?"
        ])

        let literal = QueryPlanner(
            dateParser: DatePhraseParser(calendar: calendar, now: { reference }),
            identityResolver: IdentityResolver(identities: [ContactIdentity(id: "marta", displayName: "Marta Silva", aliases: ["Marta"], handles: [handle])])
        ).plan("find messages mentioning money", scope: SearchScope(selectedSources: [.messages]), referenceDate: reference, surface: .search)
        XCTAssertEqual(literal.retrievalPolicy, .literalKeywords)
        let literalHits = try await index.search(plan: literal)
        XCTAssertTrue(literalHits.isEmpty)
    }

    func testNaturalLanguageSourceSlotsRetrieveCrossLanguageEvidenceWithinScope() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("local-digest-natural-sources-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let reference = ISO8601DateFormatter().date(from: "2026-09-16T12:00:00Z")!
        let today = calendar.startOfDay(for: reference)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let handle = "rui@example.test"
        let records = [
            IndexedRecord(id: "mail-natural", source: .mail, title: "Atualização", body: "A encomenda segue amanhã.", author: handle, participants: [handle], timestamp: today.addingTimeInterval(3_600), url: nil, threadID: nil),
            IndexedRecord(id: "calendar-natural", source: .calendar, title: "Consulta", body: "Reunião de logística", author: "Calendário", participants: [], timestamp: tomorrow.addingTimeInterval(3_600), url: nil, threadID: nil),
            IndexedRecord(id: "reminder-natural", source: .reminders, title: "Ligar", body: "Confirmar transporte", author: "Lembretes", participants: [], timestamp: tomorrow.addingTimeInterval(7_200), url: nil, threadID: nil),
            IndexedRecord(id: "note-natural", source: .notes, title: "Anotação", body: "Detalhes do embarque", author: nil, participants: [], timestamp: today.addingTimeInterval(10_800), url: nil, threadID: nil),
            IndexedRecord(id: "contact-natural", source: .contacts, title: "Rui Almeida", body: "Rui\n\(handle)", author: "Rui Almeida", participants: [handle], timestamp: .distantPast, url: nil, threadID: nil)
        ]
        let index = SQLiteIndex(databaseURL: url)
        for source in SourceKind.allCases {
            let sourceRecords = records.filter { $0.source == source }
            if !sourceRecords.isEmpty { try await index.merge(source: source, with: sourceRecords) }
        }
        let planner = QueryPlanner(
            dateParser: DatePhraseParser(calendar: calendar, now: { reference }),
            identityResolver: IdentityResolver(identities: [ContactIdentity(id: "rui", displayName: "Rui Almeida", aliases: ["Rui"], handles: [handle])])
        )
        let cases: [(String, SourceKind, StructuredQueryIntent, String)] = [
            ("What arrived in my emails today?", .mail, StructuredQueryIntent(sources: [.mail], timeframePhrase: "today"), "mail-natural"),
            ("Do I have anything scheduled tomorrow?", .calendar, StructuredQueryIntent(sources: [.calendar], timeframePhrase: "tomorrow"), "calendar-natural"),
            ("List everything I need to do tomorrow", .reminders, StructuredQueryIntent(sources: [.reminders], timeframePhrase: "tomorrow"), "reminder-natural"),
            ("What did I write today?", .notes, StructuredQueryIntent(sources: [.notes], timeframePhrase: "today"), "note-natural"),
            ("How can I reach Rui?", .contacts, StructuredQueryIntent(sources: [.contacts], personPhrase: "Rui"), "contact-natural")
        ]
        for (question, source, result, expectedID) in cases {
            let interpreter = IntentInterpreterProbe(result: result)
            let plan = await HybridQueryPlanner(planner: planner, interpreter: interpreter)
                .plan(question, scope: SearchScope(), referenceDate: reference)
            let interpreterCalls = await interpreter.callCount()
            XCTAssertEqual(interpreterCalls, 1, question)
            XCTAssertEqual(plan.constraints.sources, [source], question)
            XCTAssertEqual(plan.retrievalPolicy, .scopedSemanticEvidence, question)
            let hits = try await index.search(plan: plan, limit: 10)
            XCTAssertEqual(hits.map(\.record.id), [expectedID], question)
        }
    }
}

private actor IntentInterpreterProbe: QueryIntentInterpreting {
    let result: StructuredQueryIntent?
    let shouldThrow: Bool
    private var capturedQuestions: [String] = []

    init(result: StructuredQueryIntent? = nil, error: Bool = false) {
        self.result = result
        shouldThrow = error
    }

    func interpret(question: String, provider: AIProvider, referenceDate: Date) async throws -> StructuredQueryIntent {
        capturedQuestions.append(question)
        if shouldThrow { throw FoundationModelError.failed("fake interpreter failure") }
        return result ?? StructuredQueryIntent()
    }

    func questions() -> [String] { capturedQuestions }
    func callCount() -> Int { capturedQuestions.count }
}

private actor DelayedIntentInterpreterProbe: QueryIntentInterpreting {
    let delayNanoseconds: UInt64
    let result: StructuredQueryIntent
    private var capturedCallCount = 0

    init(delayNanoseconds: UInt64, result: StructuredQueryIntent) {
        self.delayNanoseconds = delayNanoseconds
        self.result = result
    }

    func interpret(question: String, provider: AIProvider, referenceDate: Date) async throws -> StructuredQueryIntent {
        capturedCallCount += 1
        try await Task.sleep(nanoseconds: delayNanoseconds)
        return result
    }

    func callCount() -> Int { capturedCallCount }
}

private actor AnswerStreamerProbe: AnswerStreaming {
    private var calls = 0

    func stream(
        question: String,
        evidence: [SearchHit],
        provider: AIProvider,
        intent: QueryIntent,
        referenceDate: Date,
        previousAnswer: String?,
        requireNewDetails: Bool,
        evidenceOrdering: QueryOrdering
    ) async -> AsyncThrowingStream<String, Error> {
        calls += 1
        return AsyncThrowingStream { continuation in
            continuation.yield("unexpected answer")
            continuation.finish()
        }
    }

    func callCount() -> Int { calls }
}

private actor EvidenceAnswerStreamerProbe: AnswerStreaming {
    private var capturedQuestions: [String] = []
    private var capturedEvidence: [[SearchHit]] = []

    func stream(
        question: String,
        evidence: [SearchHit],
        provider: AIProvider,
        intent: QueryIntent,
        referenceDate: Date,
        previousAnswer: String?,
        requireNewDetails: Bool,
        evidenceOrdering: QueryOrdering
    ) async -> AsyncThrowingStream<String, Error> {
        capturedQuestions.append(question)
        capturedEvidence.append(evidence)
        return AsyncThrowingStream { continuation in
            continuation.yield("Evidence received")
            continuation.finish()
        }
    }

    func questions() -> [String] { capturedQuestions }
    func evidenceByCall() -> [[SearchHit]] { capturedEvidence }
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

private actor MailProgressRecorder {
    private var detailValues: [String?] = []
    private var numericValuesStorage: [String] = []

    func detail(source: SourceKind, message: String?) { detailValues.append(message) }
    func numeric(source: SourceKind, count: Int, total: Int) { numericValuesStorage.append("\(source.rawValue):\(count):\(total)") }
    func details() -> [String?] { detailValues }
    func numericValues() -> [String] { numericValuesStorage }
}

private struct MailProgressAdapter: SourceAdapter {
    let source: SourceKind = .mail
    let record: IndexedRecord?
    let shouldFail: Bool

    init(record: IndexedRecord?, shouldFail: Bool = false) {
        self.record = record
        self.shouldFail = shouldFail
    }

    func status() async -> SourceStatus { SourceStatus(source: source, permission: .authorized, indexedCount: 0, isIndexing: false, message: nil) }
    func requestAccess() async -> SourceStatus { await status() }
    func fetchRecords() async throws -> [IndexedRecord] { record.map { [$0] } ?? [] }
    func fetchRecords(mode: IndexRefreshMode, cursor: SourceCursor?) async throws -> SourceFetchBatch {
        if shouldFail { throw SourceAdapterError.unavailable(.mail, "mailbox fetch failed") }
        return SourceFetchBatch(records: record.map { [$0] } ?? [], nextCursor: nil, isCompleteSnapshot: mode == .fullRebuild)
    }
    func fetchRecords(mode: IndexRefreshMode, cursor: SourceCursor?, progress: @escaping @Sendable (String) -> Void) async throws -> SourceFetchBatch {
        progress("Mail mailbox 1 of 1")
        if shouldFail { throw SourceAdapterError.unavailable(.mail, "mailbox fetch failed") }
        return try await fetchRecords(mode: mode, cursor: cursor)
    }
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
