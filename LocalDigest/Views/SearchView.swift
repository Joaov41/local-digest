import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Search your archive")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                    Text("Exact results first. Ask for a synthesis when you need context.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.isSearching { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 26)
            if store.hits.isEmpty {
                ContentUnavailableView("No results yet", systemImage: "magnifyingglass", description: Text("Use the toolbar search field, then index the sources you want included."))
            } else {
                List(store.hits) { hit in
                    SearchResultRow(hit: hit)
                        .listRowSeparator(.visible)
                        .listRowBackground(Color.clear)
                }
                .listStyle(.inset)
            }
        }
    }
}

struct SearchResultRow: View {
    let hit: SearchHit
    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: hit.record.source.symbol)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 27)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(hit.record.title).font(.headline).lineLimit(1)
                    Spacer()
                    Text(hit.record.timestamp.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
                if let author = hit.record.author { Text(author).font(.caption).foregroundStyle(.secondary) }
                Text(hit.record.body).font(.body).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                Label(hit.record.source.title, systemImage: hit.record.source.symbol).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 9)
    }
}
