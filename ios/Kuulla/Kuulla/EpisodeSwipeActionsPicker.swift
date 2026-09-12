import SwiftUI

// Lets the user pick which quick actions appear on one swipe direction over an episode-list row,
// and the order they appear in — the "Enabled" section's top row is the one closest to the edge
// of the screen (#568).
//
// Removing an action works as a plain swipe-to-delete on its row — SwiftUI grants that for free
// from `.onDelete`, with no need to enter edit mode first (#571: the previous system EditButton
// made the only removal path a red minus-circle hidden behind "Edit", which read as an unlabeled
// checkbox). The toolbar button here is reserved for what actually does need a mode switch:
// dragging rows into a new order, so it's labeled "Reorder" rather than the generic "Edit".
struct EpisodeSwipeActionsPicker: View {
    let title: String
    @Binding var selection: [EpisodeSwipeAction]

    @State private var isReordering = false

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
                Text("Swipe an action left to remove it. The top action appears closest to the edge of the screen\(selection.count > 1 ? " — tap Reorder to drag them into a new order." : ".")")
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
        .environment(\.editMode, .constant(isReordering ? .active : .inactive))
        .navigationTitle(title)
        .toolbar {
            // Also shown while already reordering even if a delete just dropped the count to
            // 1 or 0 — otherwise "Done" would disappear with the list stuck in edit mode and no
            // way back out.
            if isReordering || selection.count > 1 {
                Button(isReordering ? "Done" : "Reorder") {
                    isReordering.toggle()
                }
            }
        }
    }
}
