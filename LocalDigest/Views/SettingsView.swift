import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Form {
            Section("Answer provider") {
                Picker("Default provider", selection: Binding(get: { store.provider }, set: { store.setProvider($0) })) {
                    ForEach(AIProvider.allCases) { provider in Label(provider.title, systemImage: provider.symbol).tag(provider) }
                }
                .disabled(store.isAnswering)
                ForEach(AIProvider.allCases) { provider in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: provider.symbol)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.title)
                                .font(.subheadline.weight(.medium))
                            Text(store.modelAvailability[provider]?.detail ?? "Checking availability…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let availability = store.modelAvailability[provider] {
                            Image(systemName: availability.isAvailable ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .foregroundStyle(availability.isAvailable ? Color.green : Color.orange)
                                .accessibilityLabel(availability.isAvailable ? "Available" : "Unavailable")
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                Text("On-Device keeps generation on this Mac. Private Cloud Compute is an Apple service and receives only the bounded evidence used for the current answer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Index") {
                Text("The index is stored locally in Application Support/Local Digest/index.sqlite. Local Digest is read-only and never sends, edits, deletes, or creates personal items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Refresh source permissions") { Task { await store.refresh() } }
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 440)
        .padding()
        .task { await store.refreshModelAvailability() }
    }
}
