import SwiftUI
import UniformTypeIdentifiers

struct SubscriptionsView: View {
    @State private var subscriptions: [Subscription] = []
    @State private var unplayedCounts: [String: UnplayedCounts.Count] = [:]
    @State private var inProgressShowIds: Set<String> = []
    @State private var episodeStateLoaded = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var confirmingShowId: String?
    @State private var isUnsubscribeBusy = false
    @State private var unsubscribeError: String?
    @State private var sortOrder: SubscriptionSortOrder = .title
    @State private var sortSaveTask: Task<Void, Never>?
    @State private var sortSaveError: String?
    @State private var manualOrder: [String] = []
    @State private var manualSaveTask: Task<Void, Never>?
    @State private var manualSaveError: String?
    @State private var hideCaughtUpShows = false
    @State private var hideCaughtUpSaveTask: Task<Void, Never>?
    @State private var hideCaughtUpSaveError: String?
    @State private var isOpmlImporterPresented = false
    @State private var isImportingOpml = false
    @State private var opmlImportResult: OpmlImportResult?
    @State private var opmlImportError: String?

    // Matches OpmlParser.MaxDocumentBytes on the API — checked here too so an oversized file
    // fails fast without a wasted upload.
    private let maxOpmlBytes = 5 * 1024 * 1024

    // Shows with at least one unplayed or in-progress episode — the complement of "caught up".
    // Nil until the best-effort episode-state fetch completes, so the grid never hides or
    // re-sinks shows on incomplete data.
    private var activeShowIds: Set<String>? {
        episodeStateLoaded ? Set(unplayedCounts.keys).union(inProgressShowIds) : nil
    }

    private var displayedSubscriptions: [Subscription] {
        sortedSubscriptions(
            subscriptions, by: sortOrder, manualOrder: manualOrder,
            activeShowIds: activeShowIds, hideCaughtUp: hideCaughtUpShows)
    }

    @AppStorage(ShowIconSize.storageKey) private var iconSizeRaw = ShowIconSize.default.rawValue

    private let subscriptionClient = SubscriptionClient()
    private let settingsClient = SettingsClient()

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: ShowIconSize.current(iconSizeRaw).gridMinimum), spacing: 16)]
    }

    var body: some View {
        ScrollView {
            if let sortSaveError {
                Text(sortSaveError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.top)
            }
            if let hideCaughtUpSaveError {
                Text(hideCaughtUpSaveError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.top)
            }
            if let manualSaveError {
                Text(manualSaveError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.top)
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .padding()
            } else if isLoading {
                ProgressView()
                    .padding()
            } else if subscriptions.isEmpty {
                Text("You haven't subscribed to any shows yet.")
                    .foregroundStyle(.secondary)
                    .padding()
            } else if sortOrder == .manual {
                manualReorderList
            } else if displayedSubscriptions.isEmpty {
                Text("You're caught up on every show. Turn off \u{201C}Hide caught-up shows\u{201D} to see them all.")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(displayedSubscriptions) { subscription in
                        SubscriptionTile(
                            subscription: subscription,
                            unplayedCount: unplayedCounts[subscription.showId],
                            isConfirming: confirmingShowId == subscription.showId,
                            isBusy: isUnsubscribeBusy,
                            onUnsubscribeTapped: { confirmingShowId = subscription.showId },
                            onConfirm: { Task { await unsubscribe(showId: subscription.showId) } },
                            onCancel: { confirmingShowId = nil })
                    }
                }
                .padding()

                if let unsubscribeError {
                    Text(unsubscribeError)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }
            }
        }
        .navigationTitle("Subscriptions")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                sortMenu
            }
            ToolbarItem(placement: .topBarTrailing) {
                ShowIconSizeMenu()
            }
            ToolbarItem(placement: .topBarTrailing) {
                opmlMenu
            }
        }
        .fileImporter(
            isPresented: $isOpmlImporterPresented,
            allowedContentTypes: Self.opmlContentTypes,
            allowsMultipleSelection: false
        ) { result in
            Task { await importOpml(from: result) }
        }
        .alert("Import complete", isPresented: importResultAlertPresented) {
            Button("OK", role: .cancel) { opmlImportResult = nil }
        } message: {
            if let opmlImportResult {
                Text(Self.importSummary(opmlImportResult))
            }
        }
        .alert("Couldn't import that file", isPresented: importErrorAlertPresented) {
            Button("OK", role: .cancel) { opmlImportError = nil }
        } message: {
            Text(opmlImportError ?? "")
        }
        .task {
            async let subscriptionsTask: Void = loadSubscriptions()
            async let sortTask: Void = loadSortOrder()
            _ = await (subscriptionsTask, sortTask)
        }
        .refreshable {
            await loadSubscriptions()
        }
    }

    private static let opmlContentTypes: [UTType] = {
        var types: [UTType] = [.xml]
        if let opml = UTType(filenameExtension: "opml") {
            types.insert(opml, at: 0)
        }
        return types
    }()

    private var opmlMenu: some View {
        Menu {
            Button {
                opmlImportError = nil
                isOpmlImporterPresented = true
            } label: {
                Label("Import OPML\u{2026}", systemImage: "square.and.arrow.down")
            }
            .disabled(isImportingOpml)
        } label: {
            if isImportingOpml {
                ProgressView()
            } else {
                Image(systemName: "square.and.arrow.down")
            }
        }
        .accessibilityLabel("Import or export subscriptions")
    }

    private var importResultAlertPresented: Binding<Bool> {
        Binding(get: { opmlImportResult != nil }, set: { if !$0 { opmlImportResult = nil } })
    }

    private var importErrorAlertPresented: Binding<Bool> {
        Binding(get: { opmlImportError != nil }, set: { if !$0 { opmlImportError = nil } })
    }

    private static func importSummary(_ result: OpmlImportResult) -> String {
        var lines = ["Added \(result.added), skipped \(result.alreadySubscribed) already subscribed."]
        if !result.failed.isEmpty {
            lines.append("")
            lines.append("\(result.failed.count) couldn't be added:")
            lines.append(contentsOf: result.failed.map { "\u{2022} \($0.feedUrl) \u{2014} \($0.reason)" })
        }
        return lines.joined(separator: "\n")
    }

    private func importOpml(from result: Result<[URL], Error>) async {
        opmlImportError = nil
        opmlImportResult = nil

        let url: URL
        switch result {
        case .success(let urls):
            guard let first = urls.first else { return }
            url = first
        case .failure:
            // The user cancelled the picker, or it failed to open — nothing to report.
            return
        }

        isImportingOpml = true
        defer { isImportingOpml = false }

        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            opmlImportError = "That file couldn't be opened. Please try again."
            return
        }

        guard data.count <= maxOpmlBytes else {
            opmlImportError = "That file is larger than the 5 MB limit."
            return
        }

        do {
            opmlImportResult = try await subscriptionClient.importOpml(
                fileData: data, fileName: url.lastPathComponent)
            await loadSubscriptions()
        } catch ApiError.requestFailed(let statusCode) where statusCode == 413 {
            opmlImportError = "That file is larger than the 5 MB limit."
        } catch ApiError.requestFailed(let statusCode) where statusCode == 400 {
            opmlImportError = "That file couldn't be read as an OPML subscription list."
        } catch {
            opmlImportError = "Something went wrong importing that file. Please try again."
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort shows", selection: sortOrderBinding) {
                ForEach(SubscriptionSortOrder.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            Divider()
            Toggle("Hide caught-up shows", isOn: hideCaughtUpBinding)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Sort shows")
        .disabled(subscriptions.isEmpty && errorMessage == nil)
    }

    private var hideCaughtUpBinding: Binding<Bool> {
        Binding(
            get: { hideCaughtUpShows },
            set: { newValue in
                let previous = hideCaughtUpShows
                guard newValue != previous else { return }
                hideCaughtUpShows = newValue
                hideCaughtUpSaveError = nil
                // Optimistic, with rollback on failure — matches the sort-order binding.
                hideCaughtUpSaveTask?.cancel()
                hideCaughtUpSaveTask = Task {
                    do {
                        _ = try await settingsClient.updateHideCaughtUpShows(newValue)
                    } catch {
                        guard !Task.isCancelled else { return }
                        hideCaughtUpShows = previous
                        hideCaughtUpSaveError = "Couldn't save your choice. Please try again."
                    }
                }
            })
    }

    // Non-scrolling List in the page's ScrollView, held in edit mode so reorder grips always
    // show. Drag to rearrange; each move persists the full showId array (#438).
    private var manualReorderList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Drag to reorder. Your arrangement syncs across devices.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            List {
                ForEach(subscriptions) { subscription in
                    SubscriptionManualReorderRow(
                        subscription: subscription, unplayedCount: unplayedCounts[subscription.showId])
                }
                .onMove(perform: moveSubscription)
            }
            .listStyle(.plain)
            .scrollDisabled(true)
            .environment(\.editMode, .constant(.active))
            .frame(height: max(1, CGFloat(subscriptions.count)) * 64)
        }
    }

    private func moveSubscription(from offsets: IndexSet, to destination: Int) {
        subscriptions.move(fromOffsets: offsets, toOffset: destination)
        let previous = manualOrder
        let newOrder = subscriptions.map(\.showId)
        manualOrder = newOrder
        manualSaveError = nil
        manualSaveTask?.cancel()
        manualSaveTask = Task {
            do {
                _ = try await settingsClient.updateSubscriptionManualOrder(newOrder)
            } catch {
                guard !Task.isCancelled else { return }
                manualOrder = previous
                subscriptions = sortedSubscriptions(subscriptions, by: .manual, manualOrder: previous)
                manualSaveError = "Couldn't save the new order. Please try again."
            }
        }
    }

    private var sortOrderBinding: Binding<SubscriptionSortOrder> {
        Binding(
            get: { sortOrder },
            set: { newValue in
                let previous = sortOrder
                guard newValue != previous else { return }
                sortOrder = newValue
                subscriptions = sortedSubscriptions(subscriptions, by: newValue, manualOrder: manualOrder)
                sortSaveError = nil
                manualSaveError = nil
                // On failure roll back the optimistic change and surface an error, matching the
                // web pages — a silently-dropped save would otherwise revert on next launch.
                sortSaveTask?.cancel()
                sortSaveTask = Task {
                    do {
                        _ = try await settingsClient.updateSubscriptionSortOrder(newValue)
                    } catch {
                        guard !Task.isCancelled else { return }
                        sortOrder = previous
                        subscriptions = sortedSubscriptions(subscriptions, by: previous, manualOrder: manualOrder)
                        sortSaveError = "Couldn't save your sort choice. Please try again."
                    }
                }
            })
    }

    private func loadSortOrder() async {
        guard let settings = try? await settingsClient.getSettings(), !Task.isCancelled else { return }
        sortOrder = settings.subscriptionSortOrder
        manualOrder = settings.subscriptionManualOrder
        hideCaughtUpShows = settings.hideCaughtUpShows
        subscriptions = sortedSubscriptions(subscriptions, by: sortOrder, manualOrder: manualOrder)
    }

    private func loadSubscriptions() async {
        guard !isLoading else { return }

        isLoading = true
        errorMessage = nil
        // Clears any leftover unsubscribe state from a prior failed attempt so a stale error
        // or confirm prompt doesn't linger across a reload.
        unsubscribeError = nil
        confirmingShowId = nil

        do {
            let results = sortedSubscriptions(
                try await subscriptionClient.getSubscriptions(), by: sortOrder, manualOrder: manualOrder)
            if !Task.isCancelled {
                subscriptions = results
            }
        } catch {
            if !Task.isCancelled {
                errorMessage = "Something went wrong while loading your subscriptions. Please try again."
            }
        }

        // Always clears the flag, even if cancelled — mirrors LibraryView.loadShows(): the
        // best-effort badge fetch below must run after loading state clears, not only at the end.
        isLoading = false
        guard !Task.isCancelled, errorMessage == nil else { return }

        // Best-effort, run after the grid has already rendered: unplayed badges are supplementary,
        // so a failure here shouldn't hide the already-loaded subscriptions grid behind an error.
        // The same data also drives the caught-up hide/sink, gated on episodeStateLoaded so
        // nothing is hidden until both fetches have actually landed. Fetched concurrently —
        // neither depends on the other.
        async let newEpisodesTask = subscriptionClient.getNewEpisodes()
        async let inProgressTask = subscriptionClient.getInProgressShowIds()
        let newEpisodes = try? await newEpisodesTask
        let inProgress = try? await inProgressTask
        guard !Task.isCancelled else { return }
        if let newEpisodes {
            unplayedCounts = UnplayedCounts.compute(from: newEpisodes)
        }
        if let inProgress {
            inProgressShowIds = inProgress
        }
        if newEpisodes != nil, inProgress != nil {
            episodeStateLoaded = true
        }
    }

    private func unsubscribe(showId: String) async {
        guard !isUnsubscribeBusy else { return }

        isUnsubscribeBusy = true
        unsubscribeError = nil
        let removed = subscriptions.first { $0.showId == showId }
        subscriptions.removeAll { $0.showId == showId }
        confirmingShowId = nil

        do {
            try await subscriptionClient.unsubscribe(showId: showId)
        } catch {
            // Re-add only if a concurrent reload (pull-to-refresh) hasn't already settled the
            // list one way or the other — otherwise this stale snapshot could reintroduce a show
            // the refresh legitimately dropped, or duplicate one it already restored.
            if let removed, !subscriptions.contains(where: { $0.showId == removed.showId }) {
                subscriptions = sortedSubscriptions(subscriptions + [removed], by: sortOrder, manualOrder: manualOrder)
            }
            unsubscribeError = "Something went wrong while unsubscribing. Please try again."
        }

        isUnsubscribeBusy = false
    }
}

private struct SubscriptionTile: View {
    let subscription: Subscription
    let unplayedCount: UnplayedCounts.Count?
    let isConfirming: Bool
    let isBusy: Bool
    let onUnsubscribeTapped: () -> Void
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            NavigationLink(value: CatalogRoute.show(id: subscription.showId)) {
                VStack(alignment: .leading, spacing: 6) {
                    ZStack(alignment: .topTrailing) {
                        AsyncImage(url: subscription.showArtworkUrl.flatMap(URL.init)) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Color.secondary.opacity(0.2)
                        }
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                        if let unplayedCount, unplayedCount.unplayed > 0 {
                            Text(unplayedCount.hitCap ? "\(unplayedCount.unplayed)+" : "\(unplayedCount.unplayed)")
                                .font(.caption2)
                                .fontWeight(.bold)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.accentColor, in: Capsule())
                                .padding(4)
                        }
                    }

                    Text(subscription.showTitle)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }
            }
            .buttonStyle(.plain)

            if isConfirming {
                Text("Unsubscribe from \(subscription.showTitle)?")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button("Confirm", role: .destructive, action: onConfirm)
                    Button("Cancel", action: onCancel)
                }
                .font(.caption2)
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(isBusy)
            } else {
                Button("Unsubscribe", action: onUnsubscribeTapped)
                    .font(.caption2)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(.red)
            }
        }
    }
}

#Preview {
    NavigationStack {
        SubscriptionsView()
    }
}
