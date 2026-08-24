import SwiftUI

struct SettingsView: View {
    // Device-local (per docs/data-usage-network-settings.md) — @AppStorage reads/writes the same
    // UserDefaults key LocalSettings.wifiOnlyDownloads exposes for non-View code (DownloadManager).
    @AppStorage(LocalSettings.wifiOnlyDownloadsKey) private var wifiOnlyDownloads = true

    @State private var settings: UserSettings?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var archiveSaveError: String?
    @State private var autoSkipSaveError: String?
    @State private var autoDeleteSaveError: String?
    @State private var autoDownloadSaveError: String?
    // Cancelling the previous save when a new selection comes in (rather than dropping the new
    // one while a save is in flight) means the last value the user picked always wins, even if
    // they pick again before the prior PUT has resolved.
    @State private var saveTask: Task<Void, Never>?
    @State private var archiveSaveTask: Task<Void, Never>?
    @State private var autoSkipSaveTask: Task<Void, Never>?
    @State private var autoDeleteSaveTask: Task<Void, Never>?
    @State private var autoDownloadSaveTask: Task<Void, Never>?

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
            } footer: {
                if let autoSkipSaveError {
                    Text(autoSkipSaveError)
                        .foregroundStyle(.red)
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
                Toggle("Download over Wi-Fi only", isOn: $wifiOnlyDownloads)
                    .onChange(of: wifiOnlyDownloads) { _, _ in
                        // Re-evaluate queued/in-flight downloads against the new setting
                        // immediately, rather than waiting for the next Wi-Fi/cellular
                        // transition — which might not happen for a long time if the network
                        // itself hasn't actually changed.
                        DownloadManager.shared.wifiOnlyDownloadsSettingChanged()
                    }
            } footer: {
                Text("Downloads requested off Wi-Fi wait until Wi-Fi is available, and pause if Wi-Fi is lost mid-download.")
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

    private var autoDownloadNewEpisodesBinding: Binding<Bool> {
        Binding(
            get: { settings?.autoDownloadNewEpisodes ?? false },
            set: { newValue in
                autoDownloadSaveTask?.cancel()
                autoDownloadSaveTask = Task { await updateAutoDownloadNewEpisodes(newValue) }
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
        do {
            settings = try await settingsClient.getSettings()
        } catch {
            if !Task.isCancelled {
                loadError = "Something went wrong while loading your settings. Please try again."
            }
        }
        isLoading = false
    }

    private func updateUnlistenedEpisodeCount(_ value: UnlistenedEpisodeCount) async {
        guard let previous = settings else { return }

        saveError = nil
        settings = previous.with(unlistenedEpisodeCount: value)

        do {
            let updated = try await settingsClient.updateUnlistenedEpisodeCount(value)
            if !Task.isCancelled {
                settings = updated
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
            }
        } catch {
            if !Task.isCancelled {
                settings = previous
                autoDownloadSaveError = "Something went wrong while saving. Please try again."
            }
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}
