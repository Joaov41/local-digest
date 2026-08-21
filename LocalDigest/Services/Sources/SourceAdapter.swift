import Foundation

protocol SourceAdapter: Sendable {
    var source: SourceKind { get }
    var refreshCapability: SourceRefreshCapability { get }
    func status() async -> SourceStatus
    func requestAccess() async -> SourceStatus
    func fetchRecords() async throws -> [IndexedRecord]
    func fetchRecords(mode: IndexRefreshMode, cursor: SourceCursor?) async throws -> SourceFetchBatch
}

enum IndexRefreshMode: String, Codable, Sendable {
    case incremental
    case fullRebuild
}

enum SourceRefreshCapability: Equatable, Sendable {
    case incremental(String)
    case fullScan(String)
}

struct SourceCursor: Codable, Equatable, Sendable {
    var watermark: Date?
    var rawWatermark: Double?
    var rowID: Int64?
    var stableID: String?
}

struct SourceFetchBatch: Sendable {
    let records: [IndexedRecord]
    let nextCursor: SourceCursor?
    /// True means the records are a complete source snapshot and replacement
    /// is safe. Incremental batches are merged into the prior snapshot.
    let isCompleteSnapshot: Bool
}

extension SourceAdapter {
    var refreshCapability: SourceRefreshCapability {
        .fullScan("This source uses a native full scan; Full Rebuild is available for reconciliation.")
    }

    func fetchRecords(mode: IndexRefreshMode, cursor: SourceCursor?) async throws -> SourceFetchBatch {
        SourceFetchBatch(records: try await fetchRecords(), nextCursor: nil, isCompleteSnapshot: true)
    }
}

enum SourceAdapterError: LocalizedError, Sendable {
    case permissionDenied(SourceKind, String)
    case unavailable(SourceKind, String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied(let source, let message): "\(source.title): \(message)"
        case .unavailable(let source, let message): "\(source.title): \(message)"
        }
    }
}
