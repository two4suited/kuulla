import SwiftUI

struct DiscoveryView: View {
    @State private var categories: [DiscoveryCategory] = []
    @State private var trending: [Show] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let catalogClient = PodcastCatalogClient()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                } else if isLoading && trending.isEmpty && categories.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding(.horizontal)
                } else {
                    trendingSection
                    categoriesSection
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("Discover")
        .task {
            await load()
        }
        .refreshable {
            await load()
        }
    }

    private var trendingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Trending")
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(trending) { show in
                        NavigationLink(value: CatalogRoute.show(id: show.id)) {
                            DiscoveryShowTile(show: show)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("trending-show-tile")
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private var categoriesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Categories")
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            VStack(spacing: 0) {
                ForEach(categories) { category in
                    NavigationLink(value: CatalogRoute.discoveryCategory(id: category.id)) {
                        HStack {
                            Text(category.name)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("category-row")

                    if category.id != categories.last?.id {
                        Divider().padding(.leading)
                    }
                }
            }
        }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let discovery = try await catalogClient.getDiscovery()
            guard !Task.isCancelled else { return }
            categories = discovery.categories
            trending = discovery.trending
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = "Something went wrong while loading discovery. Please try again."
        }
    }
}

private struct DiscoveryShowTile: View {
    let show: Show

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: show.artworkUrl.flatMap(URL.init)) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.secondary.opacity(0.2)
            }
            .frame(width: 120, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(show.title)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(show.author)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 120)
    }
}

#Preview {
    NavigationStack {
        DiscoveryView()
    }
}
