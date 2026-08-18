import SwiftUI

struct SearchView: View {
    @State private var query = ""
    @State private var results: [Show] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?

    private let catalogClient = PodcastCatalogClient()

    var body: some View {
        List {
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            } else if isSearching {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if results.isEmpty && !trimmedQuery.isEmpty {
                Text("No shows found for \"\(trimmedQuery)\".")
                    .foregroundStyle(.secondary)
            }

            ForEach(results) { show in
                NavigationLink(value: CatalogRoute.show(id: show.id)) {
                    ShowRow(show: show)
                }
                .accessibilityIdentifier("show-row")
            }
        }
        .listStyle(.plain)
        .navigationTitle("Search")
        .searchable(text: $query, prompt: "Search for a show")
        .onChange(of: query) { _, newValue in
            scheduleSearch(for: newValue)
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func scheduleSearch(for text: String) {
        searchTask?.cancel()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            errorMessage = nil
            isSearching = false
            return
        }

        searchTask = Task {
            // Set immediately (not after the debounce delay) so the "No shows found" empty
            // state can't flash on screen for the first ~300ms of every keystroke.
            isSearching = true
            defer { isSearching = false }

            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }

            errorMessage = nil

            do {
                let shows = try await catalogClient.searchShows(query: trimmed)
                guard !Task.isCancelled else { return }
                results = shows
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = "Something went wrong while searching. Please try again."
                results = []
            }
        }
    }
}

private struct ShowRow: View {
    let show: Show

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: show.artworkUrl.flatMap(URL.init)) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.secondary.opacity(0.2)
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(show.title)
                    .font(.body)
                    .lineLimit(1)
                Text(show.author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

#Preview {
    NavigationStack {
        SearchView()
    }
}
