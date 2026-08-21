import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            DetailView()
        }
        .navigationSplitViewStyle(.balanced)
        .searchable(text: $store.searchText, placement: .toolbar, prompt: "Search your sources")
        .onSubmit(of: .search) { Task { await store.performSearch() } }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { @MainActor in
                        await Task.yield()
                        await store.indexSources()
                    }
                } label: {
                    Label(
                        store.isIndexing
                            ? (store.refreshMode == .fullRebuild ? "Rebuilding" : "Syncing")
                            : "Sync sources",
                        systemImage: store.isIndexing ? "arrow.triangle.2.circlepath" : "arrow.clockwise"
                    )
                }
                .disabled(store.isIndexing)
                Picker("AI provider", selection: Binding(get: { store.provider }, set: { store.setProvider($0) })) {
                    ForEach(AIProvider.allCases.filter(\.isSupportedOnCurrentOS)) { provider in
                        Label(provider.title, systemImage: provider.symbol).tag(provider)
                    }
                }
                .pickerStyle(.menu)
                .disabled(store.isAnswering)
            }
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        List(selection: $store.section) {
            Section("Workspace") {
                ForEach([AppSection.ask, .search, .people], id: \.self) { section in
                    Label(section.title, systemImage: section.symbol).tag(section)
                }
            }
            Section("Library") {
                ForEach([AppSection.sources, .saved], id: \.self) { section in
                    Label(section.title, systemImage: section.symbol).tag(section)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Local Digest")
        .safeAreaInset(edge: .bottom) {
            SidebarStatusView()
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
        }
    }
}

struct SidebarStatusView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        HStack(spacing: 8) {
            if store.isIndexing {
                ProgressView().controlSize(.small)
                Text("Refreshing in background")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Circle().fill(store.sourceStatuses.contains(where: { $0.permission == .authorized }) ? Color.accentColor : .secondary).frame(width: 7, height: 7)
                Text(store.sourceStatuses.filter { $0.permission == .authorized }.isEmpty ? "Connect a source to begin" : "Sources ready")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { store.section = .sources } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Open sources")
        }
        .padding(9)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct DetailView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Group {
            switch store.section {
            case .ask: AskView()
            case .search: SearchView()
            case .people: PeopleView()
            case .sources: SourcesView()
            case .saved: SavedView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.34))
    }
}
