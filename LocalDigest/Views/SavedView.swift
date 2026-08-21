import SwiftUI

struct SavedView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Group {
            if store.savedAnswers.isEmpty {
                ContentUnavailableView("No saved answers", systemImage: "bookmark", description: Text("Save a useful answer here after you have indexed a source."))
            } else {
                List(store.savedAnswers) { saved in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(saved.question)
                                .font(.headline)
                                .lineLimit(2)
                            Spacer()
                            Text(saved.savedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(saved.text)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                        Label(saved.provider.title, systemImage: saved.provider.symbol)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 8)
                    .contextMenu {
                        Button("Delete", role: .destructive) { store.deleteSavedAnswer(saved) }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
