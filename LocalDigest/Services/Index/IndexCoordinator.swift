import Foundation

actor IndexCoordinator {
    private let index: SQLiteIndex
    private let adapters: [any SourceAdapter]
    private var indexedCounts: [SourceKind: Int] = [:]
    private var indexMessages: [SourceKind: String] = [:]
    private var indexedAt: [SourceKind: Date] = [:]
    private var cursors: [SourceKind: SourceCursor] = [:]
    private var refreshInProgress = false
    private var didHydratePersistentState = false

    init(index: SQLiteIndex = SQLiteIndex(), adapters: [any SourceAdapter] = [ContactsSourceAdapter(), CalendarSourceAdapter(), RemindersSourceAdapter(), MailSourceAdapter(), NotesSourceAdapter(), MessagesSourceAdapter()]) {
        self.index = index
        self.adapters = adapters
        for source in SourceKind.allCases {
            if let date = UserDefaults.standard.object(forKey: Self.snapshotDateKey(for: source)) as? Date {
                indexedAt[source] = date
            }
            if let data = UserDefaults.standard.data(forKey: Self.cursorKey(for: source)),
               let cursor = try? JSONDecoder().decode(SourceCursor.self, from: data) {
                cursors[source] = cursor
            }
        }
    }

    func statuses() async -> [SourceStatus] {
        await hydratePersistentStateIfNeeded()
        return await withTaskGroup(of: SourceStatus.self, returning: [SourceStatus].self) { group in
            for adapter in adapters { group.addTask { await adapter.status() } }
            var values: [SourceStatus] = []
            for await status in group {
                var enriched = status
                enriched.indexedCount = indexedCounts[status.source] ?? status.indexedCount
                enriched.message = indexMessages[status.source] ?? status.message
                enriched.lastIndexedAt = indexedAt[status.source] ?? status.lastIndexedAt
                values.append(enriched)
            }
            return values.sorted { $0.source.rawValue < $1.source.rawValue }
        }
    }

    func requestAccess(for source: SourceKind) async -> SourceStatus? {
        guard let adapter = adapters.first(where: { $0.source == source }) else { return nil }
        var status = await adapter.requestAccess()
        status.indexedCount = indexedCounts[source] ?? status.indexedCount
        status.message = indexMessages[source] ?? status.message
        status.lastIndexedAt = indexedAt[source] ?? status.lastIndexedAt
        return status
    }

    func indexAll(progress: @Sendable @escaping (SourceKind, Int, Int) -> Void) async -> [SourceStatus] {
        await indexAll(mode: .incremental, progress: progress, detail: { _, _ in })
    }

    func indexAll(mode: IndexRefreshMode, progress: @Sendable @escaping (SourceKind, Int, Int) -> Void, detail: @escaping @Sendable (SourceKind, String?) -> Void = { _, _ in }) async -> [SourceStatus] {
        // A second manual sync observes the current committed snapshot and
        // returns immediately. It must never start a second source fetch.
        guard !refreshInProgress else { return await statuses() }
        refreshInProgress = true
        defer { refreshInProgress = false }

        await hydratePersistentStateIfNeeded()

        // Ensure the read connection always has a complete schema to query
        // while the first refresh is fetching source data.
        try? await index.prepare()

        await withTaskGroup(of: SourceFetchResult.self) { group in
            for adapter in adapters {
                let cursor = mode == .fullRebuild ? nil : cursors[adapter.source]
                group.addTask { [adapter] in
                    let initial = await adapter.status()
                    guard initial.permission == .authorized else {
                        return .skipped(adapter.source)
                    }

                    // Every authorized source begins fetching independently.
                    // Writes remain serialized by SQLiteIndex's actor.
                    progress(adapter.source, 0, -1)
                    do {
                        let knownIDs: Set<String>
                        if mode == .incremental, cursor != nil {
                            knownIDs = (try? await self.index.recordIDs(source: adapter.source)) ?? []
                        } else {
                            knownIDs = []
                        }
                        let batch = try await adapter.fetchRecords(mode: mode, cursor: cursor, knownRecordIDs: knownIDs) { message in
                            detail(adapter.source, message)
                        }
                        guard !Task.isCancelled else { return .cancelled(adapter.source) }
                        return .batch(
                            adapter.source,
                            batch,
                            replace: mode == .fullRebuild || batch.isCompleteSnapshot
                        )
                    } catch {
                        if Task.isCancelled { return .cancelled(adapter.source) }
                        return .failure(adapter.source, error.localizedDescription)
                    }
                }
            }

            for await result in group {
                switch result {
                case .skipped(let source):
                    detail(source, nil)
                case .batch(let source, let batch, let replace):
                    do {
                        guard !Task.isCancelled else { continue }
                        if replace {
                            try await index.replace(source: source, with: batch.records)
                        } else {
                            try await index.merge(source: source, with: batch.records)
                        }
                        let committedCount: Int
                        if replace {
                            committedCount = batch.records.count
                        } else {
                            committedCount = (try? await index.count(source: source)) ?? ((indexedCounts[source] ?? 0) + batch.records.count)
                        }
                        indexedCounts[source] = committedCount
                        let refreshedAt = Date()
                        indexedAt[source] = refreshedAt
                        UserDefaults.standard.set(refreshedAt, forKey: Self.snapshotDateKey(for: source))
                        if let nextCursor = batch.nextCursor {
                            cursors[source] = nextCursor
                            if let data = try? JSONEncoder().encode(nextCursor) {
                                UserDefaults.standard.set(data, forKey: Self.cursorKey(for: source))
                            }
                        }
                        indexMessages[source] = nil
                        detail(source, nil)
                        progress(source, committedCount, committedCount)
                    } catch {
                        indexMessages[source] = error.localizedDescription
                        detail(source, error.localizedDescription)
                        progress(source, -1, -1)
                    }
                case .failure(let source, let message):
                    indexMessages[source] = message
                    detail(source, message)
                    progress(source, -1, -1)
                case .cancelled(let source):
                    indexMessages[source] = "Indexing was cancelled before the snapshot was replaced."
                    detail(source, indexMessages[source])
                    progress(source, -1, -1)
                }
            }
        }
        return await statuses()
    }

    /// Rehydrates the UI-facing counts from the durable SQLite snapshot before
    /// querying source permissions. This keeps Search/Ask and source counts
    /// useful immediately after a relaunch without re-reading source data.
    private func hydratePersistentStateIfNeeded() async {
        guard !didHydratePersistentState else { return }
        guard (try? await index.prepare()) != nil else { return }
        var hydratedCounts: [SourceKind: Int] = [:]
        for source in SourceKind.allCases {
            guard let count = try? await index.count(source: source) else { return }
            hydratedCounts[source] = count
        }
        indexedCounts.merge(hydratedCounts) { _, new in new }
        didHydratePersistentState = true
    }

    private static func snapshotDateKey(for source: SourceKind) -> String {
        "LocalDigest.lastSnapshot.\(source.rawValue)"
    }

    private static func cursorKey(for source: SourceKind) -> String {
        "LocalDigest.cursor.\(source.rawValue)"
    }

    func search(plan: QueryPlan, limit: Int = 60) async throws -> [SearchHit] {
        try await index.search(plan: plan, limit: limit)
    }

    func conversation(threadID: String, limit: Int = 80) async throws -> [SearchHit] {
        try await index.conversation(threadID: threadID, limit: limit)
    }

    func people() async throws -> [String] { try await index.allPeople() }

    func identities() async throws -> [ContactIdentity] { try await index.identities() }
}

private enum SourceFetchResult: Sendable {
    case skipped(SourceKind)
    case batch(SourceKind, SourceFetchBatch, replace: Bool)
    case failure(SourceKind, String)
    case cancelled(SourceKind)
}
