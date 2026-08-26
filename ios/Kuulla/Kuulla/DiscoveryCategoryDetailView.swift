import SwiftUI

struct DiscoveryCategoryDetailView: View {
    let categoryId: String

    @State private var categoryName: String?
    @State private var shows: [Show] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var categoryNotFound = false

    private let catalogClient = PodcastCatalogClient()

    var body: some View {
        List {
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            } else if categoryNotFound {
                Text("This category couldn't be found.")
                    .foregroundStyle(.secondary)
            } else if isLoading && shows.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if shows.isEmpty {
                Text("No trending shows in this category right now.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(shows) { show in
                    NavigationLink(value: CatalogRoute.show(id: show.id)) {
                        ShowRow(show: show)
                    }
                    .accessibilityIdentifier("show-row")
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(categoryName ?? "Category")
        .task {
            await load()
        }
        .refreshable {
            await load()
        }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        categoryNotFound = false
        defer { isLoading = false }

        do {
            guard let result = try await catalogClient.getCategoryDiscovery(categoryId: categoryId) else {
                guard !Task.isCancelled else { return }
                categoryNotFound = true
                categoryName = nil
                shows = []
                return
            }
            guard !Task.isCancelled else { return }
            categoryName = result.category.name
            shows = result.trending
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = "Something went wrong while loading this category. Please try again."
        }
    }
}

#Preview {
    NavigationStack {
        DiscoveryCategoryDetailView(categoryId: "1301")
    }
}
