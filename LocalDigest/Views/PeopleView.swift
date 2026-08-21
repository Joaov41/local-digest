import SwiftUI

struct PeopleView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("People")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Text("Known names from indexed records. Use a person as the starting point for a focused question.")
                    .foregroundStyle(.secondary)
            }
            .padding(34)
            if store.people.isEmpty {
                ContentUnavailableView("No people indexed", systemImage: "person.2", description: Text("Allow Contacts or index Mail and Messages to build the identity map."))
            } else {
                List(store.people, id: \.self) { person in
                    Label(person, systemImage: "person.crop.circle")
                }
                .listStyle(.inset)
            }
        }
    }
}
