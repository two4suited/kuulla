import SwiftUI

// Lets the user pick which quick actions appear on one swipe direction over an episode-list row,
// and the order they appear in — the "Enabled" section's top row is the one closest to the edge
// of the screen (#568).
struct EpisodeSwipeActionsPicker: View {
    let title: String
    @Binding var selection: [EpisodeSwipeAction]

    private var available: [EpisodeSwipeAction] {
        EpisodeSwipeAction.allCases.filter { !selection.contains($0) }
    }

    var body: some View {
        List {
            Section {
                if selection.isEmpty {
                    Text("No actions — swiping does nothing.")
                        .foregroundStyle(.secondary)
                }
                ForEach(selection) { action in
                    Text(action.label)
                }
                .onDelete { selection.remove(atOffsets: $0) }
                .onMove { selection.move(fromOffsets: $0, toOffset: $1) }
            } header: {
                Text("Enabled")
            } footer: {
                Text("Drag to reorder. The top action appears closest to the edge of the screen.")
            }

            if !available.isEmpty {
                Section("Available") {
                    ForEach(available) { action in
                        Button {
                            selection.append(action)
                        } label: {
                            Label(action.label, systemImage: "plus.circle")
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
        .toolbar {
            EditButton()
        }
    }
}
