import SwiftData
import SwiftUI

struct SettingsView: View {
    // Device-local (per docs/data-usage-network-settings.md) — @AppStorage reads/writes the same
    // UserDefaults keys LocalSettings exposes for non-View code (DownloadManager, AudioPlayer).
    @AppStorage(LocalSettings.wifiOnlyDownloadsKey) private var wifiOnlyDownloads = true
    @AppStorage(LocalSettings.wifiOnlyStreamingKey) private var wifiOnlyStreaming = false

    // #43: settingsSyncEngine pulls another device's changes into UserSettingsRecord on launch/
    // foreground/background refresh; this view mirrors its own successful writes into the same
    // record (see mirrorAcceptedWrite) so the local store stays authoritative between syncs.
    @Environment(\.settingsSyncEngine) private var syncEngine
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
    @State private var smartSpeedSaveTask: Task<Void, Never>?
    @State private var notificationsEnabledSaveTask: Task<Void, Never>?

    private let settingsClient = SettingsClient()

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
        }
        .navigationTitle("Settings")
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
        isLoading = true
        loadError = nil

        // Pulls any change made on another device first (#43), so the very first render already
        // reflects the latest last-write-wins state rather than momentarily showing a stale local
        // value that then flips once sync catches up.
        await syncEngine?.syncNow()

        if let local = await fetchLocalRecord() {
            settings = local
        } else {
            // No local mirror yet (first launch, or nothing has ever been synced/saved) — fall
            // back to a plain GET, same as before #43, and seed the mirror from it.
            do {
                let fetched = try await settingsClient.getSettings()
                settings = fetched
                await mirrorAcceptedWrite(fetched)
            } catch {
                if !Task.isCancelled {
                    loadError = "Something went wrong while loading your settings. Please try again."
                }
            }
        }

        isLoading = false
    }

    // Re-pulls remote changes and, if the local mirror moved (another device's write landed),
    // applies it to this view's in-memory state. Cheap no-op when nothing changed.
    private func refreshFromRemote() async {
        await syncEngine?.syncNow()
        if let local = await fetchLocalRecord() {
            settings = local
        }
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

    private func updateSmartSpeed(_ value: Bool) async {
        guard let previous = settings else { return }

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
}

#Preview {
    NavigationStack {
        SettingsView()
    }
    .modelContainer(for: UserSettingsRecord.self, inMemory: true)
}
