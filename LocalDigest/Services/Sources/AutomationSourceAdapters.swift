import Foundation
import ApplicationServices
import AppKit

final class MailSourceAdapter: SourceAdapter, @unchecked Sendable {
    let source: SourceKind = .mail
    private let state = PermissionState(source: .mail)
    let refreshCapability: SourceRefreshCapability = .incremental("Received-date cursor with a seven-day overlap; older edits require Full Rebuild.")

    func status() async -> SourceStatus {
        SourceStatus(source: source, permission: await state.permission, indexedCount: 0, isIndexing: false, message: await state.message)
    }

    func requestAccess() async -> SourceStatus {
        let script = "tell application \"Mail\" to get name of every account"
        do {
            // The helper process is intentionally used for long-running reads,
            // but TCC authorization must be requested by Local Digest itself.
            // Otherwise macOS can attribute the first Apple Event to
            // /usr/bin/osascript and the Allow button appears to do nothing.
            try await AppleScriptRunner.requestAutomationPermission(for: source)
            _ = try await AppleScriptRunner.run(script, source: source)
            await state.set(.authorized, message: nil)
        } catch {
            let permission: SourcePermission = if case SourceAdapterError.permissionDenied = error { .denied } else { .notDetermined }
            await state.set(permission, message: error.localizedDescription)
        }
        return await status()
    }

    func fetchRecords() async throws -> [IndexedRecord] {
        try await fetchRecords(mode: .fullRebuild, cursor: nil).records
    }

    func fetchRecords(mode: IndexRefreshMode, cursor: SourceCursor?) async throws -> SourceFetchBatch {
        guard await status().permission == .authorized else { throw SourceAdapterError.permissionDenied(source, "Allow Mail automation in System Settings.") }
        let mailboxes = try await Self.mailboxes()
        var records: [IndexedRecord] = []
        if mode == .incremental, let cursor {
            let lookback = Self.lookbackSeconds(for: cursor)
            for mailbox in mailboxes {
                let script = Self.incrementalRecordsScript(
                    accountIndex: mailbox.accountIndex,
                    mailboxIndex: mailbox.mailboxIndex,
                    lookbackSeconds: lookback
                )
                records.append(contentsOf: Self.parse(try await AppleScriptRunner.run(script, source: source)))
            }
        } else {
            for mailbox in mailboxes {
                for range in Self.messageRanges(count: mailbox.messageCount) {
                    let script = Self.recordsScript(for: mailbox, range: range)
                    records.append(contentsOf: Self.parse(try await AppleScriptRunner.run(script, source: source)))
                }
            }
        }
        let nextCursor = Self.nextCursor(records, prior: cursor)
        return SourceFetchBatch(
            records: records,
            nextCursor: nextCursor,
            isCompleteSnapshot: mode == .fullRebuild || cursor == nil
        )
    }

    private struct Mailbox: Sendable {
        let accountIndex: Int
        let mailboxIndex: Int
        let messageCount: Int
    }

    private static let messageChunkSize = 50

    static func messageRanges(count: Int) -> [ClosedRange<Int>] {
        guard count > 0 else { return [] }
        return stride(from: 1, through: count, by: messageChunkSize).map { start in
            start...min(start + messageChunkSize - 1, count)
        }
    }

    private static func mailboxes() async throws -> [Mailbox] {
        let script = """
        tell application "Mail"
            set output to ""
            set fieldSeparator to ASCII character 31
            set recordSeparator to ASCII character 30
            set accountIndex to 0
            repeat with a in every account
                set accountIndex to accountIndex + 1
                set mailboxIndex to 0
                repeat with mb in every mailbox of a
                    set mailboxIndex to mailboxIndex + 1
                    try
                        set messageCount to count of messages of mb
                    on error
                        set messageCount to 0
                    end try
                    set output to output & (accountIndex as text) & fieldSeparator & (mailboxIndex as text) & fieldSeparator & (messageCount as text) & recordSeparator
                end repeat
            end repeat
            return output
        end tell
        """
        let value = try await AppleScriptRunner.run(script, source: .mail)
        return value.split(separator: "\u{1E}", omittingEmptySubsequences: true).compactMap { record in
            let fields = record.split(separator: "\u{1F}", maxSplits: 2).compactMap { Int($0) }
            guard fields.count == 3, fields[0] > 0, fields[1] > 0 else { return nil }
            return Mailbox(accountIndex: fields[0], mailboxIndex: fields[1], messageCount: max(0, fields[2]))
        }
    }

    private static func recordsScript(for mailbox: Mailbox, range: ClosedRange<Int>) -> String {
        recordsScript(accountIndex: mailbox.accountIndex, mailboxIndex: mailbox.mailboxIndex, range: range)
    }

    static func recordsScript(accountIndex: Int, mailboxIndex: Int, range: ClosedRange<Int>) -> String {
        """
        tell application "Mail"
            set output to ""
            set fieldSeparator to ASCII character 31
            set recordSeparator to ASCII character 30
            set targetAccount to account \(accountIndex)
            set targetMailbox to mailbox \(mailboxIndex) of targetAccount
            set currentCount to count of messages of targetMailbox
            if currentCount >= \(range.lowerBound) then
                set endIndex to \(range.upperBound)
                if currentCount < endIndex then set endIndex to currentCount
                repeat with m in (messages \(range.lowerBound) thru endIndex of targetMailbox)
                    try
                        set output to output & (id of m as text) & fieldSeparator & (subject of m as text) & fieldSeparator & (sender of m as text) & fieldSeparator & (date received of m as text) & fieldSeparator & (content of m as text) & recordSeparator
                    end try
                end repeat
            end if
            return output
        end tell
        """
    }

    static func incrementalRecordsScript(accountIndex: Int, mailboxIndex: Int, lookbackSeconds: Int) -> String {
        """
        tell application "Mail"
            set output to ""
            set fieldSeparator to ASCII character 31
            set recordSeparator to ASCII character 30
            set cutoffDate to (current date) - \(max(0, lookbackSeconds))
            set targetAccount to account \(accountIndex)
            set targetMailbox to mailbox \(mailboxIndex) of targetAccount
            repeat with m in (messages of targetMailbox whose date received is greater than or equal to cutoffDate)
                try
                    set output to output & (id of m as text) & fieldSeparator & (subject of m as text) & fieldSeparator & (sender of m as text) & fieldSeparator & (date received of m as text) & fieldSeparator & (content of m as text) & recordSeparator
                end try
            end repeat
            return output
        end tell
        """
    }

    static func lookbackSeconds(for cursor: SourceCursor, now: Date = Date()) -> Int {
        guard let watermark = cursor.watermark else { return 7 * 24 * 60 * 60 }
        return max(7 * 24 * 60 * 60, Int(now.timeIntervalSince(watermark)) + 7 * 24 * 60 * 60)
    }

    private static func parse(_ value: String) -> [IndexedRecord] {
        value.split(separator: "\u{1E}", omittingEmptySubsequences: true).compactMap { record in
            let fields = record.split(separator: "\u{1F}", maxSplits: 4).map(String.init)
            guard fields.count == 5 else { return nil }
            let date = DateParser.parse(fields[3]) ?? .distantPast
            return IndexedRecord(id: "mail-\(fields[0])", source: .mail, title: fields[1], body: fields[4], author: fields[2], participants: [fields[2]], timestamp: date, url: nil, threadID: nil)
        }
    }

    private static func nextCursor(_ records: [IndexedRecord], prior: SourceCursor?) -> SourceCursor? {
        let dated = records.filter { $0.timestamp != .distantPast }
        guard let newest = dated.max(by: { $0.timestamp < $1.timestamp }) else { return prior }
        return SourceCursor(watermark: newest.timestamp, rawWatermark: nil, rowID: nil, stableID: newest.id)
    }
}

final class NotesSourceAdapter: SourceAdapter, @unchecked Sendable {
    let source: SourceKind = .notes
    private let state = PermissionState(source: .notes)
    let refreshCapability: SourceRefreshCapability = .incremental("Modification-date cursor with a seven-day overlap; Full Rebuild reconciles deletions.")

    func status() async -> SourceStatus {
        SourceStatus(source: source, permission: await state.permission, indexedCount: 0, isIndexing: false, message: await state.message)
    }

    func requestAccess() async -> SourceStatus {
        let script = "tell application \"Notes\" to get name of every folder"
        do {
            try await AppleScriptRunner.requestAutomationPermission(for: source)
            _ = try await AppleScriptRunner.run(script, source: source)
            await state.set(.authorized, message: nil)
        } catch {
            let permission: SourcePermission = if case SourceAdapterError.permissionDenied = error { .denied } else { .notDetermined }
            await state.set(permission, message: error.localizedDescription)
        }
        return await status()
    }

    func fetchRecords() async throws -> [IndexedRecord] {
        try await fetchRecords(mode: .fullRebuild, cursor: nil).records
    }

    func fetchRecords(mode: IndexRefreshMode, cursor: SourceCursor?) async throws -> SourceFetchBatch {
        guard await status().permission == .authorized else { throw SourceAdapterError.permissionDenied(source, "Allow Notes automation in System Settings.") }
        let lookback = mode == .incremental && cursor != nil ? MailSourceAdapter.lookbackSeconds(for: cursor!) : nil
        let script = Self.recordsScript(lookbackSeconds: lookback)
        let value = try await AppleScriptRunner.run(script, source: source)
        let records = value.split(separator: "\u{1E}", omittingEmptySubsequences: true).compactMap { record -> IndexedRecord? in
            let fields = record.split(separator: "\u{1F}", maxSplits: 3).map(String.init)
            guard fields.count == 4 else { return nil }
            return IndexedRecord(id: "note-\(fields[0])", source: .notes, title: fields[1], body: Self.htmlToPlainText(fields[2]), author: nil, participants: [], timestamp: DateParser.parse(fields[3]) ?? .distantPast, url: nil, threadID: nil)
        }
        let nextCursor = records.filter { $0.timestamp != .distantPast }.max(by: { $0.timestamp < $1.timestamp }).map {
            SourceCursor(watermark: $0.timestamp, rawWatermark: nil, rowID: nil, stableID: $0.id)
        } ?? cursor
        return SourceFetchBatch(records: records, nextCursor: nextCursor, isCompleteSnapshot: mode == .fullRebuild || cursor == nil)
    }

    static func recordsScript(lookbackSeconds: Int?) -> String {
        let cutoff = lookbackSeconds.map { "set cutoffDate to (current date) - \($0)" } ?? ""
        let filter = lookbackSeconds == nil ? "" : " whose modification date is greater than or equal to cutoffDate"
        return """
        tell application "Notes"
            set output to ""
            set fieldSeparator to ASCII character 31
            set recordSeparator to ASCII character 30
            \(cutoff)
            repeat with a in every account
                repeat with n in every note of a\(filter)
                    try
                        set timestampText to ""
                        try
                            set timestampText to (modification date of n as text)
                        on error
                            try
                                set timestampText to (creation date of n as text)
                            end try
                        end try
                        set output to output & (id of n as text) & fieldSeparator & (name of n as text) & fieldSeparator & (body of n as text) & fieldSeparator & timestampText & recordSeparator
                    end try
                end repeat
            end repeat
            return output
        end tell
        """
    }

    static func htmlToPlainText(_ html: String) -> String {
        guard !html.isEmpty else { return "" }
        if let data = html.data(using: .utf8),
           let attributed = try? NSAttributedString(
               data: data,
               options: [
                   .documentType: NSAttributedString.DocumentType.html,
                   .characterEncoding: String.Encoding.utf8.rawValue
               ],
               documentAttributes: nil
           ) {
            return normalizePlainText(attributed.string)
        }

        var fallback = html
        fallback = fallback.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        fallback = fallback.replacingOccurrences(of: "</(div|p|h[1-6]|li|tr)>\\s*", with: "\n", options: [.regularExpression, .caseInsensitive])
        fallback = fallback.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        fallback = fallback.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
        return normalizePlainText(fallback)
    }

    private static func normalizePlainText(_ text: String) -> String {
        text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

actor PermissionState {
    private let persistenceKey: String
    private(set) var permission: SourcePermission = .notDetermined
    private(set) var message: String?

    init(source: SourceKind) {
        persistenceKey = "LocalDigest.permission.\(source.rawValue)"
        if let rawValue = UserDefaults.standard.string(forKey: persistenceKey),
           let persisted = SourcePermission(rawValue: rawValue) {
            permission = persisted
            if persisted == .authorized {
                message = "Previously authorized; Sync will verify access."
            }
        }
    }

    func set(_ permission: SourcePermission, message: String?) {
        self.permission = permission
        self.message = message
        UserDefaults.standard.set(permission.rawValue, forKey: persistenceKey)
    }
}

enum AppleScriptRunner {
    /// Requests Automation permission from the signed Local Digest process.
    /// Long source reads still run in /usr/bin/osascript, but that child must
    /// not be responsible for the initial TCC consent prompt.
    static func requestAutomationPermission(for source: SourceKind) async throws {
        guard let bundleIdentifier = automationBundleIdentifier(for: source) else { return }
        try await Task.detached(priority: .userInitiated) {
            try determineAutomationPermission(
                for: source,
                bundleIdentifier: bundleIdentifier
            )
        }.value
    }

    static func automationBundleIdentifier(for source: SourceKind) -> String? {
        switch source {
        case .mail: "com.apple.mail"
        case .notes: "com.apple.Notes"
        default: nil
        }
    }

    private static func determineAutomationPermission(for source: SourceKind, bundleIdentifier: String) throws {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty else {
            throw SourceAdapterError.unavailable(source, "Open \(source.title) and try Allow again so macOS can request Automation permission.")
        }

        let bundleData = Data(bundleIdentifier.utf8)
        var target = AEAddressDesc()
        let createStatus = bundleData.withUnsafeBytes { bytes in
            AECreateDesc(
                typeApplicationBundleID,
                bytes.baseAddress,
                bundleData.count,
                &target
            )
        }
        guard createStatus == noErr else {
            throw SourceAdapterError.unavailable(source, "Could not prepare the \(source.title) Automation permission request (OSStatus \(createStatus)).")
        }
        defer { AEDisposeDesc(&target) }

        let status = AEDeterminePermissionToAutomateTarget(
            &target,
            typeWildCard,
            typeWildCard,
            true
        )
        guard status == noErr else {
            throw automationError(source: source, status: status)
        }
    }

    private static func automationError(source: SourceKind, status: OSStatus) -> SourceAdapterError {
        switch status {
        case OSStatus(errAEEventNotPermitted):
            return .permissionDenied(source, "macOS denied Automation for \(source.title). Allow Local Digest to control \(source.title) in System Settings > Privacy & Security > Automation.")
        case OSStatus(procNotFound):
            return .unavailable(source, "\(source.title) is not running. Open it and try Allow again.")
        case OSStatus(errAEEventWouldRequireUserConsent):
            return .permissionDenied(source, "macOS requires Automation consent for \(source.title). Allow Local Digest to control it in System Settings > Privacy & Security > Automation.")
        default:
            return .unavailable(source, "Could not verify Automation permission for \(source.title) (OSStatus \(status)).")
        }
    }

    /// Runs osascript out of process. No Apple Event call or synchronous wait
    /// occurs on the app's MainActor. Output is redirected to files so a
    /// verbose script cannot deadlock on a full pipe.
    static func run(_ source: String, source sourceKind: SourceKind) async throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalDigest-AppleScript-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scriptURL = directory.appendingPathComponent("script.applescript")
        let outputURL = directory.appendingPathComponent("stdout")
        let errorURL = directory.appendingPathComponent("stderr")
        defer { try? FileManager.default.removeItem(at: directory) }

        try source.write(to: scriptURL, atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [scriptURL.path]
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        let cancellation = ProcessCancellationBox(process: process)
        let status: Int32 = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { terminated in
                    continuation.resume(returning: terminated.terminationStatus)
                }
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }, onCancel: {
            cancellation.terminate()
        })

        try? outputHandle.close()
        try? errorHandle.close()
        if Task.isCancelled { throw CancellationError() }
        let output = (try? Data(contentsOf: outputURL)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let errorText = (try? Data(contentsOf: errorURL)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        guard status == 0 else {
            throw failure(source: sourceKind, status: status, message: errorText)
        }
        return output.trimmingCharacters(in: .newlines)
    }

    private static func failure(source: SourceKind, status: Int32, message: String) -> SourceAdapterError {
        let lowercased = message.lowercased()
        if lowercased.contains("not authorized")
            || lowercased.contains("not permitted")
            || lowercased.contains("not allowed")
            || lowercased.contains("1743") {
            return .permissionDenied(source, "macOS denied automation for \(source.title). Allow Local Digest to control \(source.title) in System Settings > Privacy & Security > Automation.")
        }
        let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return .unavailable(source, detail.isEmpty ? "AppleScript helper exited with status \(status)." : detail)
    }
}

private final class ProcessCancellationBox: @unchecked Sendable {
    private let process: Process

    init(process: Process) {
        self.process = process
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }
}

private enum DateParser {
    static func parse(_ value: String) -> Date? {
        let formats = ["EEE MMM d HH:mm:ss z yyyy", "yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd HH:mm:ss"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}
