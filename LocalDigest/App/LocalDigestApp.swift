import SwiftUI

@main
struct LocalDigestApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup("Local Digest") {
            RootView()
                .environmentObject(store)
                .task { await store.refresh() }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(after: .textEditing) {
                Button("New conversation") { Task { await store.startNewConversation() } }
                    .keyboardShortcut("n", modifiers: [.command])
                Button("Ask Local Digest") { store.section = .ask }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Search Sources") { store.section = .search }
                    .keyboardShortcut("f", modifiers: [.command])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}
