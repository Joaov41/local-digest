import SwiftUI

struct SourcesView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sources")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                    Text("Sync updates new and changed records where a source cursor is available. Full Rebuild rereads and reconciles deletions. Both run in the background while your last committed snapshot remains searchable.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 700, alignment: .leading)
                    if store.isIndexing {
                        Label("Refreshing in the background. Your last completed snapshot remains available.", systemImage: "arrow.triangle.2.circlepath")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                VStack(spacing: 0) {
                    ForEach(store.sourceStatuses) { status in
                        SourceRow(status: status)
                        if status.source != store.sourceStatuses.last?.source { Divider() }
                    }
                }
                .padding(6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                VStack(alignment: .leading, spacing: 8) {
                    Label("Refresh behavior", systemImage: "arrow.triangle.2.circlepath")
                        .font(.headline)
                    ForEach(store.sourceStatuses) { status in
                        Text("\(status.source.title): \(status.source.refreshPolicyDescription)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                HStack {
                    Label("Read-only by design", systemImage: "lock")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    HStack(spacing: 10) {
                        Button {
                            Task { @MainActor in
                                await Task.yield()
                                await store.indexSources()
                            }
                        } label: { Label("Sync changes", systemImage: "arrow.clockwise") }
                            .buttonStyle(.glassProminent)
                            .disabled(store.isIndexing)
                        Button {
                            Task { @MainActor in
                                await Task.yield()
                                await store.rebuildIndex()
                            }
                        } label: { Label("Full Rebuild", systemImage: "arrow.triangle.2.circlepath") }
                            .buttonStyle(.bordered)
                            .disabled(store.isIndexing)
                    }
                }
            }
            .padding(34)
            .frame(maxWidth: 900, alignment: .leading)
        }
    }
}

struct SourceRow: View {
    @EnvironmentObject private var store: AppStore
    let status: SourceStatus

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: status.source.symbol)
                .font(.title3)
                .foregroundStyle(status.permission == .authorized ? Color.accentColor : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(status.source.title).font(.headline)
                Text(status.message ?? status.permission.title).font(.caption).foregroundStyle(.secondary)
                if let lastIndexedAt = status.lastIndexedAt {
                    Text("Snapshot refreshed \(lastIndexedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if store.isRequestingAccess(for: status.source) {
                Label("Checking…", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if status.isIndexing { ProgressView().controlSize(.small) }
            else if status.permission == .authorized {
                Text("\(status.indexedCount) indexed").font(.caption).foregroundStyle(.secondary)
            } else {
                Button(status.permission == .denied ? "System Settings" : "Allow") {
                    if status.permission == .denied { openSettings() }
                    else {
                        Task { @MainActor in
                            await Task.yield()
                            await store.requestAccess(for: status.source)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(store.isRequestingAccess(for: status.source))
            }
        }
        .padding(14)
    }

    private func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
    }
}
