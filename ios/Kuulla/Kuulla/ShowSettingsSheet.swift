import SwiftUI

struct ShowSettingsSheet: View {
    let showId: String
    let showTitle: String

    @Environment(\.dismiss) private var dismiss
    @State private var settings: ShowSettings?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var archiveSaveError: String?
    @State private var autoSkipSaveError: String?
    // Cancelling the previous save when a new selection comes in (rather than dropping the new
    // one while a save is in flight) means the last value the user picked always wins, even if
    // they pick again before the prior PUT has resolved.
    @State private var saveTask: Task<Void, Never>?
    @State private var archiveSaveTask: Task<Void, Never>?
    @State private var autoSkipSaveTask: Task<Void, Never>?

    private let settingsClient = SettingsClient()

    var body: some View {
        NavigationStack {
            Form {
                if let loadError {
                    Text(loadError)
                        .foregroundStyle(.red)
                }

                Section {
                    Picker("Unlistened episodes to show", selection: overrideBinding) {
                        Text("Use global default").tag(UnlistenedEpisodeCount?.none)
                        ForEach(UnlistenedEpisodeCount.allCases) { option in
                            Text(option.label).tag(UnlistenedEpisodeCount?.some(option))
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
                    Picker("Auto-archive played episodes", selection: archiveOverrideBinding) {
                        Text("Use global default").tag(AutoArchiveRule?.none)
                        ForEach(AutoArchiveRule.allCases) { option in
                            Text(option.label).tag(AutoArchiveRule?.some(option))
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
                    Picker("Auto-skip intro", selection: autoSkipIntroOverrideBinding) {
                        Text("Use global default").tag(Int?.none)
                        autoSkipPickerOptions(for: settings?.autoSkipIntroSeconds)
                    }
                    .disabled(settings == nil)

                    Picker("Auto-skip outro", selection: autoSkipOutroOverrideBinding) {
                        Text("Use global default").tag(Int?.none)
                        autoSkipPickerOptions(for: settings?.autoSkipOutroSeconds)
                    }
                    .disabled(settings == nil)
                } footer: {
                    if let autoSkipSaveError {
                        Text(autoSkipSaveError)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(showTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
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
        }
    }

    private var overrideBinding: Binding<UnlistenedEpisodeCount?> {
        Binding(
            get: { settings?.unlistenedEpisodeCount },
            set: { newValue in
                saveTask?.cancel()
                saveTask = Task { await updateOverride(newValue) }
            }
        )
    }

    private var archiveOverrideBinding: Binding<AutoArchiveRule?> {
        Binding(
            get: { settings?.autoArchiveRule },
            set: { newValue in
                archiveSaveTask?.cancel()
                archiveSaveTask = Task { await updateArchiveOverride(newValue) }
            }
        )
    }

    private var autoSkipIntroOverrideBinding: Binding<Int?> {
        Binding(
            get: { settings?.autoSkipIntroSeconds },
            set: { newValue in
                autoSkipSaveTask?.cancel()
                autoSkipSaveTask = Task {
                    await updateAutoSkipOverride(introSeconds: newValue, outroSeconds: settings?.autoSkipOutroSeconds)
                }
            }
        )
    }

    private var autoSkipOutroOverrideBinding: Binding<Int?> {
        Binding(
            get: { settings?.autoSkipOutroSeconds },
            set: { newValue in
                autoSkipSaveTask?.cancel()
                autoSkipSaveTask = Task {
                    await updateAutoSkipOverride(introSeconds: settings?.autoSkipIntroSeconds, outroSeconds: newValue)
                }
            }
        )
    }

    // The presets don't cover every value the API accepts (0...3600), so an override saved from
    // elsewhere that doesn't match one of them gets a synthesized "Custom" row rather than
    // silently snapping to the nearest preset.
    @ViewBuilder
    private func autoSkipPickerOptions(for currentValue: Int?) -> some View {
        ForEach(AutoSkipDuration.allCases) { option in
            Text(option.label).tag(Int?.some(option.rawValue))
        }
        if let currentValue, AutoSkipDuration(rawValue: currentValue) == nil {
            Text("Custom (\(currentValue)s)").tag(Int?.some(currentValue))
        }
    }

    private func loadSettings() async {
        isLoading = true
        loadError = nil
        do {
            settings = try await settingsClient.getShowSettings(showId: showId)
        } catch {
            if !Task.isCancelled {
                loadError = "Something went wrong while loading this podcast's settings. Please try again."
            }
        }
        isLoading = false
    }

    private func updateOverride(_ value: UnlistenedEpisodeCount?) async {
        guard let previous = settings else { return }

        saveError = nil
        settings = ShowSettings(
            id: previous.id, userId: previous.userId, showId: previous.showId,
            unlistenedEpisodeCount: value, version: previous.version, autoArchiveRule: previous.autoArchiveRule,
            autoSkipIntroSeconds: previous.autoSkipIntroSeconds, autoSkipOutroSeconds: previous.autoSkipOutroSeconds)

        do {
            let updated = try await settingsClient.updateShowUnlistenedEpisodeCount(showId: showId, value: value)
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

    private func updateArchiveOverride(_ value: AutoArchiveRule?) async {
        guard let previous = settings else { return }

        archiveSaveError = nil
        settings = ShowSettings(
            id: previous.id, userId: previous.userId, showId: previous.showId,
            unlistenedEpisodeCount: previous.unlistenedEpisodeCount, version: previous.version, autoArchiveRule: value,
            autoSkipIntroSeconds: previous.autoSkipIntroSeconds, autoSkipOutroSeconds: previous.autoSkipOutroSeconds)

        do {
            let updated = try await settingsClient.updateShowAutoArchiveRule(showId: showId, value: value)
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

    private func updateAutoSkipOverride(introSeconds: Int?, outroSeconds: Int?) async {
        guard let previous = settings else { return }

        autoSkipSaveError = nil
        settings = ShowSettings(
            id: previous.id, userId: previous.userId, showId: previous.showId,
            unlistenedEpisodeCount: previous.unlistenedEpisodeCount, version: previous.version,
            autoArchiveRule: previous.autoArchiveRule, autoSkipIntroSeconds: introSeconds, autoSkipOutroSeconds: outroSeconds)

        do {
            let updated = try await settingsClient.updateShowAutoSkip(
                showId: showId, introSeconds: introSeconds, outroSeconds: outroSeconds)
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
}

#Preview {
    ShowSettingsSheet(showId: "preview-show", showTitle: "Preview Show")
}
