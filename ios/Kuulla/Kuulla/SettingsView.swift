import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct SettingsView: View {
    // Device-local (per docs/data-usage-network-settings.md) — @AppStorage reads/writes the same
    // UserDefaults keys LocalSettings exposes for non-View code (DownloadManager, AudioPlayer).
    @AppStorage(LocalSettings.wifiOnlyDownloadsKey) private var wifiOnlyDownloads = true
    @AppStorage(LocalSettings.wifiOnlyStreamingKey) private var wifiOnlyStreaming = false

    // #43: settingsSyncEngine pulls another device's changes into UserSettingsRecord on launch/
    // foreground/background refresh; this view mirrors its own successful writes into the same
    // record (see mirrorAcceptedWrite) so the local store stays authoritative between syncs.
    @Environment(\.settingsSyncEngine) private var syncEngine
    @Environment(\.catalogRefresh) private var catalogRefresh
    @Environment(\.scenePhase) private var scenePhase

    @State private var settings: UserSettings?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var archiveSaveError: String?
    @State private var autoSkipSaveError: String?
    @State private var autoDeleteSaveError: String?
    @State private var autoDownloadSaveError: String?
    @State private var autoAddUpNextSaveError: String?
    @State private var upNextInsertPositionSaveError: String?
    @State private var leadingSwipeActionsSaveError: String?
    @State private var trailingSwipeActionsSaveError: String?
    @State private var smartSpeedSaveError: String?
    @State private var notificationsEnabledSaveError: String?
    // Cancelling the previous save when a new selection comes in (rather than dropping the new
    // one while a save is in flight) means the last value the user picked always wins, even if
    // they pick again before the prior PUT has resolved.
    @State private var saveTask: Task<Void, Never>?
    @State private var archiveSaveTask: Task<Void, Never>?
    @State private var autoSkipSaveTask: Task<Void, Never>?
    @State private var autoDeleteSaveTask: Task<Void, Never>?
    @State private var autoDownloadSaveTask: Task<Void, Never>?
    @State private var autoAddUpNextSaveTask: Task<Void, Never>?
    @State private var upNextInsertPositionSaveTask: Task<Void, Never>?
    @State private var leadingSwipeActionsSaveTask: Task<Void, Never>?
    @State private var trailingSwipeActionsSaveTask: Task<Void, Never>?
    @State private var smartSpeedSaveTask: Task<Void, Never>?
    @State private var notificationsEnabledSaveTask: Task<Void, Never>?

    // Counts in-flight update*() calls below. refreshFromRemote() (triggered by scenePhase
    // going active, e.g. the user switches away mid-edit and back) reads the on-disk mirror and
    // assigns it wholesale to `settings` — but that mirror is only updated by mirrorAcceptedWrite
    // *after* a PUT round-trips, so a refresh landing between an update*()'s optimistic write and
    // its PUT completing would clobber the just-picked value back to the stale one (#571). Every
    // update*() increments this before its optimistic write and decrements it when done (success,
    // failure, or cancellation), so refreshFromRemote can tell such a write is in flight and skip
    // the clobbering assignment rather than fight it.
    @State private var pendingSaveCount = 0

    @State private var isOpmlImporterPresented = false
    @State private var isImportingOpml = false
    @State private var opmlImportResult: OpmlImportResult?
    @State private var opmlImportError: String?
    @State private var isExportingOpml = false
    @State private var exportedOpmlFileURL: URL?
    @State private var opmlExportError: String?

    // Matches OpmlParser.MaxDocumentBytes on the API — checked here too so an oversized file
    // fails fast without a wasted upload.
    private let maxOpmlBytes = 5 * 1024 * 1024

    private let settingsClient = SettingsClient()
    private let subscriptionClient = SubscriptionClient()

    var body: some View {
        Form {
            if let loadError {
                Text(loadError)
                    .foregroundStyle(.red)
            }

            Section {
                Picker("Unlistened episodes to show", selection: unlistenedEpisodeCountBinding) {
                    ForEach(UnlistenedEpisodeCount.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .disabled(settings == nil)
            } footer: {
                if let saveError {
                    Text(saveError)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Picker("Auto-archive played episodes", selection: autoArchiveRuleBinding) {
                    ForEach(AutoArchiveRule.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .disabled(settings == nil)
            } footer: {
                if let archiveSaveError {
                    Text(archiveSaveError)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Picker("Auto-skip intro", selection: autoSkipIntroBinding) {
                    autoSkipPickerOptions(for: settings?.autoSkipIntroSeconds ?? 0)
                }
                .disabled(settings == nil)

                Picker("Auto-skip outro", selection: autoSkipOutroBinding) {
                    autoSkipPickerOptions(for: settings?.autoSkipOutroSeconds ?? 0)
                }
                .disabled(settings == nil)

                Toggle("SmartSpeed", isOn: smartSpeedBinding)
                    .disabled(settings == nil)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let autoSkipSaveError {
                        Text(autoSkipSaveError)
                            .foregroundStyle(.red)
                    }
                    if let smartSpeedSaveError {
                        Text(smartSpeedSaveError)
                            .foregroundStyle(.red)
                    } else {
                        Text("Trims silence and boosts quiet passages during playback.")
                    }
                }
            }

            Section {
                Toggle("Add new episodes to Up Next", isOn: autoAddNewEpisodesToUpNextBinding)
                    .disabled(settings == nil)

                Picker("Add to", selection: upNextInsertPositionBinding) {
                    ForEach(UpNextInsertPosition.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .disabled(settings == nil)
            } header: {
                Text("Up Next")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let autoAddUpNextSaveError {
                        Text(autoAddUpNextSaveError)
                            .foregroundStyle(.red)
                    }
                    if let upNextInsertPositionSaveError {
                        Text(upNextInsertPositionSaveError)
                            .foregroundStyle(.red)
                    }
                    if autoAddUpNextSaveError == nil && upNextInsertPositionSaveError == nil {
                        Text("New episodes from your subscriptions are queued automatically. Override this per show from a show's page.")
                    }
                }
            }

            Section {
                NavigationLink {
                    EpisodeSwipeActionsPicker(title: "Left Swipe", selection: leadingSwipeActionsBinding)
                } label: {
                    HStack {
                        Text("Left swipe")
                        Spacer()
                        Text(swipeActionsSummary(settings?.leadingSwipeActions ?? []))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .disabled(settings == nil)

                NavigationLink {
                    EpisodeSwipeActionsPicker(title: "Right Swipe", selection: trailingSwipeActionsBinding)
                } label: {
                    HStack {
                        Text("Right swipe")
                        Spacer()
                        Text(swipeActionsSummary(settings?.trailingSwipeActions ?? [.addToPlaylist, .markPlayed]))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .disabled(settings == nil)
            } header: {
                Text("Episode Swipe Actions")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let leadingSwipeActionsSaveError {
                        Text(leadingSwipeActionsSaveError)
                            .foregroundStyle(.red)
                    }
                    if let trailingSwipeActionsSaveError {
                        Text(trailingSwipeActionsSaveError)
                            .foregroundStyle(.red)
                    }
                    if leadingSwipeActionsSaveError == nil && trailingSwipeActionsSaveError == nil {
                        Text("Choose which quick actions appear when you swipe an episode row left or right.")
                    }
                }
            }

            Section {
                Toggle("Auto-download new episodes", isOn: autoDownloadNewEpisodesBinding)
                    .disabled(settings == nil)

                Picker("Delete downloads", selection: autoDeleteRuleBinding) {
                    ForEach(AutoDeleteRule.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .disabled(settings == nil)

                if settings?.autoDeleteRule == .afterDays {
                    Stepper(value: autoDeleteAfterDaysBinding, in: 1...365) {
                        let days = settings?.autoDeleteAfterDays ?? 7
                        Text("After \(days) day\(days == 1 ? "" : "s")")
                    }
                }

                NavigationLink(value: CatalogRoute.downloads) {
                    Text("Manage Downloads")
                }
            } header: {
                Text("Downloads & Storage")
            } footer: {
                // Independent, not else-if: an auto-download save failing shouldn't hide an
                // auto-delete save failure that's also currently set, or vice versa.
                VStack(alignment: .leading, spacing: 4) {
                    if let autoDownloadSaveError {
                        Text(autoDownloadSaveError)
                            .foregroundStyle(.red)
                    }
                    if let autoDeleteSaveError {
                        Text(autoDeleteSaveError)
                            .foregroundStyle(.red)
                    }
                }
            }

            Section {
                Toggle("New episode notifications", isOn: notificationsEnabledBinding)
                    .disabled(settings == nil)
            } header: {
                Text("Notifications")
            } footer: {
                if let notificationsEnabledSaveError {
                    Text(notificationsEnabledSaveError)
                        .foregroundStyle(.red)
                } else {
                    Text("Get notified when a show you're subscribed to publishes a new episode. Override per show from its settings.")
                }
            }

            Section {
                Toggle("Stream over Wi-Fi only", isOn: $wifiOnlyStreaming)

                Toggle("Download over Wi-Fi only", isOn: $wifiOnlyDownloads)
                    .onChange(of: wifiOnlyDownloads) { _, _ in
                        // Re-evaluate queued/in-flight downloads against the new setting
                        // immediately, rather than waiting for the next Wi-Fi/cellular
                        // transition — which might not happen for a long time if the network
                        // itself hasn't actually changed.
                        DownloadManager.shared.wifiOnlyDownloadsSettingChanged()
                    }
            } header: {
                Text("Data Usage & Network")
            } footer: {
                Text("Streaming refuses to start off Wi-Fi when enabled. Downloads requested off Wi-Fi wait until Wi-Fi is available, and pause if Wi-Fi is lost mid-download.")
            }

            Section {
                Button {
                    opmlImportError = nil
                    isOpmlImporterPresented = true
                } label: {
                    HStack {
                        Label("Import Subscriptions (OPML)", systemImage: "square.and.arrow.down")
                        if isImportingOpml {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isImportingOpml)

                Button {
                    Task { await exportOpml() }
                } label: {
                    HStack {
                        Label("Export Subscriptions (OPML)", systemImage: "square.and.arrow.up")
                        if isExportingOpml {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isExportingOpml)
            } header: {
                Text("Import & Export")
            } footer: {
                Text("Bring your library over from another podcast app by importing an OPML file. Shows you already follow are skipped.")
            }

            Section {
                Button {
                    Task { await catalogRefresh?.refreshAll() }
                } label: {
                    HStack {
                        Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                        if catalogRefresh?.isRefreshing == true {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(catalogRefresh == nil || catalogRefresh?.isRefreshing == true)
            } header: {
                Text("Sync")
            } footer: {
                // The app pulls your library on launch and in the background; use this to pull
                // the latest shows, episodes and playlists on demand.
                if let statusMessage = catalogRefresh?.statusMessage {
                    Text(statusMessage)
                } else if let syncError = catalogRefresh?.lastError {
                    Text(syncError)
                        .foregroundStyle(.red)
                } else if let lastSynced = catalogRefresh?.lastRefreshedAt {
                    Text("Last synced \(lastSynced.formatted(.relative(presentation: .named))).")
                } else {
                    Text("Pull the latest shows, episodes and playlists from the server.")
                }
            }

            Section {
                Button("Sign Out", role: .destructive) {
                    // Awaited *before* signOut() clears the auth token, not fired afterward —
                    // ApiClient attaches the bearer token from AuthManager.validIdToken() when it
                    // actually builds the request (several suspension points deep inside the
                    // unregister call), so calling signOut() synchronously right after scheduling
                    // this Task doesn't guarantee the token is still valid by the time the request
                    // goes out. Firing it unauthenticated would get rejected with 401 and leave
                    // the device's token orphaned server-side. The tradeoff is the button waits on
                    // one fast local network call rather than updating instantly.
                    Task {
                        await PushNotificationManager.shared.unregisterCurrentDevice()
                        AuthManager.shared.signOut()
                    }
                }
            }
        }
        .navigationTitle("Settings")
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
        .alert("Couldn't export your subscriptions", isPresented: exportErrorAlertPresented) {
            Button("OK", role: .cancel) { opmlExportError = nil }
        } message: {
            Text(opmlExportError ?? "")
        }
        .sheet(isPresented: shareSheetPresented) {
            if let exportedOpmlFileURL {
                OpmlShareSheet(fileURL: exportedOpmlFileURL)
            }
        }
        .overlay {
            if isLoading && settings == nil {
                ProgressView()
            }
        }
        .task {
            await loadSettings()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Re-syncs when this view resumes in the foreground with another device's change
            // waiting — same trigger KuullaApp uses for episodes/playlists, scoped here so it
            // only re-fetches while Settings is actually the visible screen.
            guard newPhase == .active, settings != nil else { return }
            Task { await refreshFromRemote() }
        }
    }

    private var unlistenedEpisodeCountBinding: Binding<UnlistenedEpisodeCount> {
        Binding(
            get: { settings?.unlistenedEpisodeCount ?? .five },
            set: { newValue in
                saveTask?.cancel()
                saveTask = Task { await updateUnlistenedEpisodeCount(newValue) }
            }
        )
    }

    private var autoArchiveRuleBinding: Binding<AutoArchiveRule> {
        Binding(
            get: { settings?.autoArchiveRule ?? .never },
            set: { newValue in
                archiveSaveTask?.cancel()
                archiveSaveTask = Task { await updateAutoArchiveRule(newValue) }
            }
        )
    }

    private var autoSkipIntroBinding: Binding<Int> {
        Binding(
            get: { settings?.autoSkipIntroSeconds ?? 0 },
            set: { newValue in
                autoSkipSaveTask?.cancel()
                autoSkipSaveTask = Task {
                    await updateAutoSkip(introSeconds: newValue, outroSeconds: settings?.autoSkipOutroSeconds ?? 0)
                }
            }
        )
    }

    private var autoSkipOutroBinding: Binding<Int> {
        Binding(
            get: { settings?.autoSkipOutroSeconds ?? 0 },
            set: { newValue in
                autoSkipSaveTask?.cancel()
                autoSkipSaveTask = Task {
                    await updateAutoSkip(introSeconds: settings?.autoSkipIntroSeconds ?? 0, outroSeconds: newValue)
                }
            }
        )
    }

    private var autoDeleteRuleBinding: Binding<AutoDeleteRule> {
        Binding(
            get: { settings?.autoDeleteRule ?? .never },
            set: { newValue in
                autoDeleteSaveTask?.cancel()
                autoDeleteSaveTask = Task {
                    await updateAutoDeleteRule(newValue, afterDays: settings?.autoDeleteAfterDays ?? 7)
                }
            }
        )
    }

    private var autoDeleteAfterDaysBinding: Binding<Int> {
        Binding(
            get: { settings?.autoDeleteAfterDays ?? 7 },
            set: { newValue in
                autoDeleteSaveTask?.cancel()
                autoDeleteSaveTask = Task {
                    await updateAutoDeleteRule(settings?.autoDeleteRule ?? .never, afterDays: newValue)
                }
            }
        )
    }

    private var smartSpeedBinding: Binding<Bool> {
        Binding(
            get: { settings?.smartSpeed ?? false },
            set: { newValue in
                smartSpeedSaveTask?.cancel()
                smartSpeedSaveTask = Task { await updateSmartSpeed(newValue) }
            }
        )
    }

    private var notificationsEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings?.notificationsEnabled ?? true },
            set: { newValue in
                notificationsEnabledSaveTask?.cancel()
                notificationsEnabledSaveTask = Task { await updateNotificationsEnabled(newValue) }
            }
        )
    }

    private var autoDownloadNewEpisodesBinding: Binding<Bool> {
        Binding(
            get: { settings?.autoDownloadNewEpisodes ?? false },
            set: { newValue in
                autoDownloadSaveTask?.cancel()
                autoDownloadSaveTask = Task { await updateAutoDownloadNewEpisodes(newValue) }
            }
        )
    }

    private var autoAddNewEpisodesToUpNextBinding: Binding<Bool> {
        Binding(
            get: { settings?.autoAddNewEpisodesToUpNext ?? false },
            set: { newValue in
                autoAddUpNextSaveTask?.cancel()
                autoAddUpNextSaveTask = Task { await updateAutoAddNewEpisodesToUpNext(newValue) }
            }
        )
    }

    private var upNextInsertPositionBinding: Binding<UpNextInsertPosition> {
        Binding(
            get: { settings?.upNextInsertPosition ?? .bottom },
            set: { newValue in
                upNextInsertPositionSaveTask?.cancel()
                upNextInsertPositionSaveTask = Task { await updateUpNextInsertPosition(newValue) }
            }
        )
    }

    private var leadingSwipeActionsBinding: Binding<[EpisodeSwipeAction]> {
        Binding(
            get: { settings?.leadingSwipeActions ?? [] },
            set: { newValue in
                guard let previous = settings else { return }
                // Apply optimistically right away (unlike every other binding here, which
                // applies it inside the update*() Task) so the picker's delete/reorder
                // animation isn't held up by saveDebounce below (#577). pendingSaveCount is
                // bumped here too, synchronously with that write — incrementing it inside the
                // Task instead would leave a gap (until the Task actually gets scheduled) where
                // the optimistic value is live but refreshFromRemote() doesn't yet know to skip
                // clobbering it, reopening #571.
                settings = previous.with(leadingSwipeActions: newValue)
                pendingSaveCount += 1
                leadingSwipeActionsSaveTask?.cancel()
                leadingSwipeActionsSaveTask = Task { await updateLeadingSwipeActions(newValue, revertingTo: previous) }
            }
        )
    }

    private var trailingSwipeActionsBinding: Binding<[EpisodeSwipeAction]> {
        Binding(
            get: { settings?.trailingSwipeActions ?? [.addToPlaylist, .markPlayed] },
            set: { newValue in
                guard let previous = settings else { return }
                settings = previous.with(trailingSwipeActions: newValue)
                pendingSaveCount += 1
                trailingSwipeActionsSaveTask?.cancel()
                trailingSwipeActionsSaveTask = Task { await updateTrailingSwipeActions(newValue, revertingTo: previous) }
            }
        )
    }

    private func swipeActionsSummary(_ actions: [EpisodeSwipeAction]) -> String {
        actions.isEmpty ? "None" : actions.map(\.label).joined(separator: ", ")
    }

    // The presets don't cover every value the API accepts (0...3600), so a value saved from
    // elsewhere (or a future release with different presets) that doesn't match one of them gets
    // a synthesized "Custom" row rather than silently snapping to the nearest preset (or "Off").
    @ViewBuilder
    private func autoSkipPickerOptions(for currentValue: Int) -> some View {
        ForEach(AutoSkipDuration.allCases) { option in
            Text(option.label).tag(option.rawValue)
        }
        if AutoSkipDuration(rawValue: currentValue) == nil {
            Text("Custom (\(currentValue)s)").tag(currentValue)
        }
    }

    private func loadSettings() async {
        loadError = nil

        // Local-first: paint the on-device mirror immediately so Settings is interactive right
        // away. The cross-device pull (#43) then runs in the background below and folds in any
        // newer last-write-wins state — a brief flip to a synced value is a better trade than a
        // blocking spinner that leaves every control disabled until the network round trip lands.
        if let local = await fetchLocalRecord() {
            settings = local
        } else {
            // No local mirror yet (first launch, or nothing has ever been synced/saved) — there's
            // nothing to show, so block on a plain GET (same as before #43) and seed the mirror.
            isLoading = true
            do {
                let fetched = try await settingsClient.getSettings()
                settings = fetched
                await mirrorAcceptedWrite(fetched)
            } catch {
                if !Task.isCancelled {
                    loadError = "Something went wrong while loading your settings. Please try again."
                }
            }
            isLoading = false
        }

        // Background pull of another device's changes; updates `settings` in place if LWW moved
        // the local mirror. A cheap no-op poll when we just seeded from the GET above.
        await refreshFromRemote()
    }

    // Re-pulls remote changes and, if the local mirror moved (another device's write landed),
    // applies it to this view's in-memory state. Cheap no-op when nothing changed.
    private func refreshFromRemote() async {
        await syncEngine?.syncNow()
        // Skip the assignment while an update*() above is mid-flight: its optimistic write
        // already reflects the user's pick, but the on-disk mirror this reads only catches up
        // after that call's own PUT completes (mirrorAcceptedWrite) — assigning here first would
        // revert the screen to the stale value (#571).
        guard pendingSaveCount == 0, let local = await fetchLocalRecord() else { return }
        settings = local
    }

    // Reads through syncEngine's own ModelContext (SyncEngine.read), not the view's
    // @Environment(\.modelContext) — the two are different ModelContext instances over the same
    // store, and a fetch made right after syncEngine.syncNow()/write() isn't guaranteed to
    // observe that write if it goes through a different context (see SyncEngine.read's doc
    // comment, and EpisodeDetailView.restoreAutoPlayed for the same hazard elsewhere).
    private func fetchLocalRecord() async -> UserSettings? {
        guard let syncEngine else { return nil }
        let id = UserSettingsRecord.localId
        let record = try? await syncEngine.read { context in
            try context.fetch(FetchDescriptor<UserSettingsRecord>(predicate: #Predicate { $0.id == id })).first
        }
        return record?.asUserSettings
    }

    // Mirrors a just-accepted write (either this device's own PUT response, or the initial GET
    // fallback above) into UserSettingsRecord with isDirty: false — the server has already seen
    // this exact value, so there's nothing new for the next sync push to send.
    private func mirrorAcceptedWrite(_ settings: UserSettings) async {
        guard let syncEngine else { return }
        do {
            try await syncEngine.write { context in
                let id = UserSettingsRecord.localId
                let descriptor = FetchDescriptor<UserSettingsRecord>(predicate: #Predicate { $0.id == id })
                if let existing = try context.fetch(descriptor).first {
                    existing.apply(settings, isDirty: false)
                } else {
                    context.insert(UserSettingsRecord(from: settings, isDirty: false))
                }
            }
        } catch {
            // Best-effort mirror only — the write already succeeded server-side (this is called
            // with an already-accepted response), so a failure here just means the local cache
            // stays one write behind until the next successful sync pulls it back in line.
        }
    }

    private func updateUnlistenedEpisodeCount(_ value: UnlistenedEpisodeCount) async {
        guard let previous = settings else { return }
        pendingSaveCount += 1
        defer { pendingSaveCount -= 1 }

        saveError = nil
        settings = previous.with(unlistenedEpisodeCount: value)

        do {
            let updated = try await settingsClient.updateUnlistenedEpisodeCount(value)
            if !Task.isCancelled {
                settings = updated
                await mirrorAcceptedWrite(updated)
            }
        } catch {
            if !Task.isCancelled {
                settings = previous
                saveError = "Something went wrong while saving. Please try again."
            }
        }
    }

    private func updateAutoArchiveRule(_ value: AutoArchiveRule) async {
        guard let previous = settings else { return }
        pendingSaveCount += 1
        defer { pendingSaveCount -= 1 }

        archiveSaveError = nil
        settings = previous.with(autoArchiveRule: value)

        do {
            let updated = try await settingsClient.updateAutoArchiveRule(value)
            if !Task.isCancelled {
                settings = updated
                await mirrorAcceptedWrite(updated)
            }
        } catch {
            if !Task.isCancelled {
                settings = previous
                archiveSaveError = "Something went wrong while saving. Please try again."
            }
        }
    }

    private func updateAutoSkip(introSeconds: Int, outroSeconds: Int) async {
        guard let previous = settings else { return }
        pendingSaveCount += 1
        defer { pendingSaveCount -= 1 }

        autoSkipSaveError = nil
        settings = previous.with(autoSkipIntroSeconds: introSeconds, autoSkipOutroSeconds: outroSeconds)

        do {
            let updated = try await settingsClient.updateAutoSkip(introSeconds: introSeconds, outroSeconds: outroSeconds)
            if !Task.isCancelled {
                settings = updated
                await mirrorAcceptedWrite(updated)
            }
        } catch {
            if !Task.isCancelled {
                settings = previous
                autoSkipSaveError = "Something went wrong while saving. Please try again."
            }
        }
    }

    private func updateAutoDeleteRule(_ rule: AutoDeleteRule, afterDays: Int) async {
        guard let previous = settings else { return }
        pendingSaveCount += 1
        defer { pendingSaveCount -= 1 }

        autoDeleteSaveError = nil
        settings = previous.with(autoDeleteRule: rule, autoDeleteAfterDays: afterDays)

        do {
            let updated = try await settingsClient.updateAutoDeleteRule(rule, afterDays: afterDays)
            if !Task.isCancelled {
                settings = updated
                await mirrorAcceptedWrite(updated)
            }
        } catch {
            if !Task.isCancelled {
                settings = previous
                autoDeleteSaveError = "Something went wrong while saving. Please try again."
            }
        }
    }

    private func updateAutoDownloadNewEpisodes(_ value: Bool) async {
        guard let previous = settings else { return }
        pendingSaveCount += 1
        defer { pendingSaveCount -= 1 }

        autoDownloadSaveError = nil
        settings = previous.with(autoDownloadNewEpisodes: value)

        do {
            let updated = try await settingsClient.updateAutoDownloadNewEpisodes(value)
            if !Task.isCancelled {
                settings = updated
                await mirrorAcceptedWrite(updated)
            }
        } catch {
            if !Task.isCancelled {
                settings = previous
                autoDownloadSaveError = "Something went wrong while saving. Please try again."
            }
        }
    }

    private func updateAutoAddNewEpisodesToUpNext(_ value: Bool) async {
        guard let previous = settings else { return }
        pendingSaveCount += 1
        defer { pendingSaveCount -= 1 }

        autoAddUpNextSaveError = nil
        settings = previous.with(autoAddNewEpisodesToUpNext: value)

        do {
            let updated = try await settingsClient.updateAutoAddNewEpisodesToUpNext(value)
            if !Task.isCancelled {
                settings = updated
                await mirrorAcceptedWrite(updated)
            }
        } catch {
            if !Task.isCancelled {
                settings = previous
                autoAddUpNextSaveError = "Something went wrong while saving. Please try again."
            }
        }
    }

    private func updateUpNextInsertPosition(_ value: UpNextInsertPosition) async {
        guard let previous = settings else { return }
        pendingSaveCount += 1
        defer { pendingSaveCount -= 1 }

        upNextInsertPositionSaveError = nil
        settings = previous.with(upNextInsertPosition: value)

        do {
            let updated = try await settingsClient.updateUpNextInsertPosition(value)
            if !Task.isCancelled {
                settings = updated
                await mirrorAcceptedWrite(updated)
            }
        } catch {
            if !Task.isCancelled {
                settings = previous
                upNextInsertPositionSaveError = "Something went wrong while saving. Please try again."
            }
        }
    }

    // The picker's row deletes/reorders each cancel the prior save and start a new one, same as
    // every other binding's save Task — but a single swipe-to-delete gesture can fire its
    // `.onDelete` closure twice in quick succession (a known SwiftUI behavior), and Task
    // cancellation doesn't reliably stop a PUT that's already in flight on the wire. Two such
    // PUTs to the same field-specific endpoint race each other against the server's ETag retry
    // loop (SettingsService.UpdateSettingsWithRetryAsync), which after exhausting its attempts
    // throws and surfaces here as a save failure (#577). Waiting a beat before touching the
    // network lets a near-simultaneous second call cancel this one first, so only the last of a
    // rapid burst actually reaches the server.
    private static let swipeActionsSaveDebounce: Duration = .milliseconds(300)

    private func updateLeadingSwipeActions(_ value: [EpisodeSwipeAction], revertingTo previous: UserSettings) async {
        // pendingSaveCount was already bumped by the binding setter above, synchronously with
        // the optimistic write — see its comment. This only owns the matching decrement.
        defer { pendingSaveCount -= 1 }

        leadingSwipeActionsSaveError = nil
        try? await Task.sleep(for: Self.swipeActionsSaveDebounce)
        guard !Task.isCancelled else { return }

        do {
            let updated = try await settingsClient.updateLeadingSwipeActions(value)
            if !Task.isCancelled {
                settings = updated
                await mirrorAcceptedWrite(updated)
            }
        } catch {
            if !Task.isCancelled {
                settings = previous
                leadingSwipeActionsSaveError = "Something went wrong while saving. Please try again."
            }
        }
    }

    private func updateTrailingSwipeActions(_ value: [EpisodeSwipeAction], revertingTo previous: UserSettings) async {
        defer { pendingSaveCount -= 1 }

        trailingSwipeActionsSaveError = nil
        try? await Task.sleep(for: Self.swipeActionsSaveDebounce)
        guard !Task.isCancelled else { return }

        do {
            let updated = try await settingsClient.updateTrailingSwipeActions(value)
            if !Task.isCancelled {
                settings = updated
                await mirrorAcceptedWrite(updated)
            }
        } catch {
            if !Task.isCancelled {
                settings = previous
                trailingSwipeActionsSaveError = "Something went wrong while saving. Please try again."
            }
        }
    }

    private func updateSmartSpeed(_ value: Bool) async {
        guard let previous = settings else { return }
        pendingSaveCount += 1
        defer { pendingSaveCount -= 1 }

        smartSpeedSaveError = nil
        settings = previous.with(smartSpeed: value)

        do {
            let updated = try await settingsClient.updateSmartSpeed(value)
            if !Task.isCancelled {
                settings = updated
                await mirrorAcceptedWrite(updated)
            }
        } catch {
            if !Task.isCancelled {
                settings = previous
                smartSpeedSaveError = "Something went wrong while saving. Please try again."
            }
        }
    }

    private func updateNotificationsEnabled(_ value: Bool) async {
        guard let previous = settings else { return }
        pendingSaveCount += 1
        defer { pendingSaveCount -= 1 }

        notificationsEnabledSaveError = nil
        settings = previous.with(notificationsEnabled: value)

        do {
            let updated = try await settingsClient.updateNotificationsEnabled(value)
            if !Task.isCancelled {
                settings = updated
                await mirrorAcceptedWrite(updated)
            }
        } catch {
            if !Task.isCancelled {
                settings = previous
                notificationsEnabledSaveError = "Something went wrong while saving. Please try again."
            }
        }
    }

    // MARK: - OPML import & export

    private static let opmlContentTypes: [UTType] = {
        var types: [UTType] = [.xml]
        if let opml = UTType(filenameExtension: "opml") {
            types.insert(opml, at: 0)
        }
        return types
    }()

    private var importResultAlertPresented: Binding<Bool> {
        Binding(get: { opmlImportResult != nil }, set: { if !$0 { opmlImportResult = nil } })
    }

    private var importErrorAlertPresented: Binding<Bool> {
        Binding(get: { opmlImportError != nil }, set: { if !$0 { opmlImportError = nil } })
    }

    private var exportErrorAlertPresented: Binding<Bool> {
        Binding(get: { opmlExportError != nil }, set: { if !$0 { opmlExportError = nil } })
    }

    private var shareSheetPresented: Binding<Bool> {
        Binding(get: { exportedOpmlFileURL != nil }, set: { if !$0 { exportedOpmlFileURL = nil } })
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
            let importResult = try await subscriptionClient.importOpml(
                fileData: data, fileName: url.lastPathComponent)
            opmlImportResult = importResult
            if importResult.added > 0 {
                await catalogRefresh?.refreshAll()
            }
        } catch ApiError.requestFailed(let statusCode) where statusCode == 413 {
            opmlImportError = "That file is larger than the 5 MB limit."
        } catch ApiError.requestFailed(let statusCode) where statusCode == 400 {
            opmlImportError = "That file couldn't be read as an OPML subscription list."
        } catch {
            opmlImportError = "Something went wrong importing that file. Please try again."
        }
    }

    private func exportOpml() async {
        guard !isExportingOpml else { return }

        opmlExportError = nil
        isExportingOpml = true
        defer { isExportingOpml = false }

        do {
            let data = try await subscriptionClient.exportOpml()
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("kuulla-subscriptions.opml")
            try data.write(to: fileURL, options: .atomic)
            exportedOpmlFileURL = fileURL
        } catch {
            opmlExportError = "Something went wrong exporting your subscriptions. Please try again."
        }
    }
}

// Wraps UIActivityViewController so the OPML export can be saved to Files, AirDropped, mailed,
// etc. SwiftUI's ShareLink needs its item up front; export fetches asynchronously first, so the
// file URL only exists once the download has landed.
private struct OpmlShareSheet: UIViewControllerRepresentable {
    let fileURL: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

#Preview {
    NavigationStack {
        SettingsView()
    }
    .modelContainer(for: UserSettingsRecord.self, inMemory: true)
}
