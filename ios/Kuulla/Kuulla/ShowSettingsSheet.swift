import SwiftData
import SwiftUI

struct ShowSettingsSheet: View {
    let showId: String
    let showTitle: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var settings: ShowSettings?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var archiveSaveError: String?
    @State private var autoSkipSaveError: String?
    @State private var playbackSpeedSaveError: String?
    @State private var autoDownloadSaveError: String?
    @State private var autoDownloadRulesSaveError: String?
    @State private var autoDeleteSaveError: String?
    @State private var autoAddUpNextSaveError: String?
    @State private var upNextInsertPositionSaveError: String?
    @State private var playNextBehaviorSaveError: String?
    @State private var smartSpeedSaveError: String?
    @State private var voiceBoostSaveError: String?
    @State private var trimSilenceSaveError: String?
    @State private var notificationsEnabledSaveError: String?
    // Cancelling the previous save when a new selection comes in (rather than dropping the new
    // one while a save is in flight) means the last value the user picked always wins, even if
    // they pick again before the prior PUT has resolved.
    @State private var saveTask: Task<Void, Never>?
    @State private var archiveSaveTask: Task<Void, Never>?
    @State private var autoSkipSaveTask: Task<Void, Never>?
    @State private var playbackSpeedSaveTask: Task<Void, Never>?
    @State private var autoDownloadSaveTask: Task<Void, Never>?
    @State private var autoDownloadRulesSaveTask: Task<Void, Never>?
    @State private var autoDeleteSaveTask: Task<Void, Never>?
    @State private var autoAddUpNextSaveTask: Task<Void, Never>?
    @State private var upNextInsertPositionSaveTask: Task<Void, Never>?
    @State private var playNextBehaviorSaveTask: Task<Void, Never>?
    @State private var smartSpeedSaveTask: Task<Void, Never>?
    @State private var voiceBoostSaveTask: Task<Void, Never>?
    @State private var trimSilenceSaveTask: Task<Void, Never>?
    @State private var notificationsEnabledSaveTask: Task<Void, Never>?
    // Bumped on every playback-speed override change; the endpoint is a plain read-then-upsert,
    // so unlike the other settings here (where cancelling the previous Task is enough — an
    // in-flight PUT racing a newer one just means the last-arriving response wins, and the last
    // *selection* still overwrites the UI on each change), two in-flight speed PUTs could land
    // out of order and leave a stale value persisted. This version, combined with chaining saves
    // behind their predecessor in savePlaybackSpeedOverride, keeps requests in-order and
    // coalesces away any that are superseded before they'd even be sent.
    @State private var playbackSpeedSaveVersion = 0
    // The per-show insert-position control only makes sense when new episodes are actually being
    // auto-added for this show, which can be true purely via the global default — so the sheet
    // needs the global auto-add value, not just this show's override.
    @State private var globalAutoAddNewEpisodesToUpNext = false
    // The auto-download-rules controls only make sense when new episodes are actually being
    // auto-downloaded for this show, which can be true purely via the global default — same
    // rationale as globalAutoAddNewEpisodesToUpNext above.
    @State private var globalAutoDownloadNewEpisodes = false
    // Read alongside globalAutoDownloadNewEpisodes so updateAutoDownloadRulesOverride can compute
    // this show's effective limit (override ?? global) to enforce immediately after a save,
    // without a second round trip just to look up the global value.
    @State private var globalAutoDownloadEpisodeLimit = 0

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

                Section {
                    Picker("Playback speed", selection: playbackSpeedOverrideBinding) {
                        Text("Use global default").tag(Float?.none)
                        playbackSpeedPickerOptions(for: settings?.playbackSpeed)
                    }
                    .disabled(settings == nil)
                } footer: {
                    if let playbackSpeedSaveError {
                        Text(playbackSpeedSaveError)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Picker("Auto-download new episodes", selection: autoDownloadOverrideBinding) {
                        Text("Use global default").tag(Bool?.none)
                        Text("On").tag(Bool?.some(true))
                        Text("Off").tag(Bool?.some(false))
                    }
                    .disabled(settings == nil)
                } footer: {
                    if let autoDownloadSaveError {
                        Text(autoDownloadSaveError)
                            .foregroundStyle(.red)
                    }
                }

                // Only shown when new episodes are actually being auto-downloaded for this show
                // (override or global default) — these two rules (#689) are meaningless otherwise.
                if settings?.autoDownloadNewEpisodes ?? globalAutoDownloadNewEpisodes {
                    Section {
                        Picker("Keep downloaded", selection: autoDownloadEpisodeLimitOverrideBinding) {
                            Text("Use global default").tag(Int?.none)
                            Text("All episodes").tag(Int?.some(0))
                            ForEach([1, 3, 5, 10, 20], id: \.self) { count in
                                Text("Latest \(count)").tag(Int?.some(count))
                            }
                        }
                        .disabled(settings == nil)

                        Picker("Only while charging", selection: autoDownloadChargingOnlyOverrideBinding) {
                            Text("Use global default").tag(Bool?.none)
                            Text("On").tag(Bool?.some(true))
                            Text("Off").tag(Bool?.some(false))
                        }
                        .disabled(settings == nil)
                    } footer: {
                        if let autoDownloadRulesSaveError {
                            Text(autoDownloadRulesSaveError)
                                .foregroundStyle(.red)
                        }
                    }
                }

                Section {
                    Picker("Delete downloads", selection: autoDeleteRuleOverrideBinding) {
                        Text("Use global default").tag(AutoDeleteRule?.none)
                        ForEach(AutoDeleteRule.allCases) { option in
                            Text(option.label).tag(AutoDeleteRule?.some(option))
                        }
                    }
                    .disabled(settings == nil)

                    if settings?.autoDeleteRule == .afterDays {
                        Stepper(value: autoDeleteAfterDaysOverrideBinding, in: 1...365) {
                            let days = settings?.autoDeleteAfterDays ?? 7
                            Text("After \(days) day\(days == 1 ? "" : "s")")
                        }
                        .disabled(settings == nil)
                    }
                } footer: {
                    if let autoDeleteSaveError {
                        Text(autoDeleteSaveError)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Picker("Add new episodes to Up Next", selection: autoAddUpNextOverrideBinding) {
                        Text("Use global default").tag(Bool?.none)
                        Text("On").tag(Bool?.some(true))
                        Text("Off").tag(Bool?.some(false))
                    }
                    .disabled(settings == nil)

                    if settings?.autoAddNewEpisodesToUpNext ?? globalAutoAddNewEpisodesToUpNext {
                        Picker("Add to", selection: upNextInsertPositionOverrideBinding) {
                            Text("Use global default").tag(UpNextInsertPosition?.none)
                            Text("Top of the queue").tag(UpNextInsertPosition?.some(.top))
                            Text("Bottom of the queue").tag(UpNextInsertPosition?.some(.bottom))
                        }
                        .disabled(settings == nil)
                    }
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
                    }
                }

                Section {
                    Picker("Play next", selection: playNextBehaviorOverrideBinding) {
                        Text("Use global default").tag(PlayNextBehavior?.none)
                        ForEach(PlayNextBehavior.allCases) { option in
                            Text(option.label).tag(PlayNextBehavior?.some(option))
                        }
                    }
                    .disabled(settings == nil)
                } footer: {
                    if let playNextBehaviorSaveError {
                        Text(playNextBehaviorSaveError)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Picker("SmartSpeed", selection: smartSpeedOverrideBinding) {
                        Text("Use global default").tag(Bool?.none)
                        Text("On").tag(Bool?.some(true))
                        Text("Off").tag(Bool?.some(false))
                    }
                    .disabled(settings == nil)
                } footer: {
                    if let smartSpeedSaveError {
                        Text(smartSpeedSaveError)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Picker("Voice Boost", selection: voiceBoostOverrideBinding) {
                        Text("Use global default").tag(Bool?.none)
                        Text("On").tag(Bool?.some(true))
                        Text("Off").tag(Bool?.some(false))
                    }
                    .disabled(settings == nil)
                } footer: {
                    if let voiceBoostSaveError {
                        Text(voiceBoostSaveError)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Picker("Trim Silence", selection: trimSilenceOverrideBinding) {
                        Text("Use global default").tag(Bool?.none)
                        Text("On").tag(Bool?.some(true))
                        Text("Off").tag(Bool?.some(false))
                    }
                    .disabled(settings == nil)
                } footer: {
                    if let trimSilenceSaveError {
                        Text(trimSilenceSaveError)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Picker("Notifications", selection: notificationsEnabledOverrideBinding) {
                        Text("Use global default").tag(Bool?.none)
                        Text("On").tag(Bool?.some(true))
                        Text("Off").tag(Bool?.some(false))
                    }
                    .disabled(settings == nil)
                } footer: {
                    if let notificationsEnabledSaveError {
                        Text(notificationsEnabledSaveError)
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
        // Fetched together; the global value only gates whether the per-show insert-position
        // control is shown, so `try?` — a failure there must not blank out the whole sheet.
        async let globalSettings = try? settingsClient.getSettings()
        do {
            settings = try await settingsClient.getShowSettings(showId: showId)
        } catch {
            if !Task.isCancelled {
                loadError = "Something went wrong while loading this podcast's settings. Please try again."
            }
        }
        if let globalAutoAdd = await globalSettings?.autoAddNewEpisodesToUpNext {
            globalAutoAddNewEpisodesToUpNext = globalAutoAdd
        }
        if let globalAutoDownload = await globalSettings?.autoDownloadNewEpisodes {
            globalAutoDownloadNewEpisodes = globalAutoDownload
        }
        if let globalLimit = await globalSettings?.autoDownloadEpisodeLimit {
            globalAutoDownloadEpisodeLimit = globalLimit
        }
        isLoading = false
    }

    private func updateOverride(_ value: UnlistenedEpisodeCount?) async {
        guard let previous = settings else { return }

        saveError = nil
        settings = previous.with(unlistenedEpisodeCount: value)

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
        settings = previous.with(autoArchiveRule: value)

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
        settings = previous.with(autoSkipIntroSeconds: introSeconds, autoSkipOutroSeconds: outroSeconds)

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

    private var playbackSpeedOverrideBinding: Binding<Float?> {
        Binding(
            get: { settings?.playbackSpeed },
            set: { newValue in
                updatePlaybackSpeedOverride(newValue)
            }
        )
    }

    // The presets don't cover every value the API accepts (0.5...3.0), so an override saved from
    // elsewhere that doesn't match one of them gets a synthesized "Custom" row rather than
    // silently snapping to the nearest preset, mirroring autoSkipPickerOptions above.
    @ViewBuilder
    private func playbackSpeedPickerOptions(for currentValue: Float?) -> some View {
        ForEach(PlaybackSpeedOption.allCases) { option in
            Text(option.label).tag(Float?.some(option.rawValue))
        }
        if let currentValue, PlaybackSpeedOption(rawValue: currentValue) == nil {
            Text("Custom (\(currentValue.formatted(.number.precision(.fractionLength(0...2))))x)").tag(Float?.some(currentValue))
        }
    }

    private func updatePlaybackSpeedOverride(_ value: Float?) {
        guard let previous = settings else { return }

        playbackSpeedSaveError = nil
        settings = previous.with(playbackSpeed: value)

        playbackSpeedSaveVersion += 1
        let requestVersion = playbackSpeedSaveVersion
        let previousTask = playbackSpeedSaveTask
        playbackSpeedSaveTask = Task {
            await previousTask?.value
            guard requestVersion == playbackSpeedSaveVersion else { return }

            do {
                let updated = try await settingsClient.updateShowPlaybackSpeed(showId: showId, value: value)
                if requestVersion == playbackSpeedSaveVersion {
                    settings = updated
                }
            } catch {
                if requestVersion == playbackSpeedSaveVersion {
                    settings = previous
                    playbackSpeedSaveError = "Something went wrong while saving. Please try again."
                }
            }
        }
    }

    private var autoDownloadOverrideBinding: Binding<Bool?> {
        Binding(
            get: { settings?.autoDownloadNewEpisodes },
            set: { newValue in
                autoDownloadSaveTask?.cancel()
                autoDownloadSaveTask = Task { await updateAutoDownloadOverride(newValue) }
            }
        )
    }

    private func updateAutoDownloadOverride(_ value: Bool?) async {
        guard let previous = settings else { return }

        autoDownloadSaveError = nil
        settings = previous.with(autoDownloadNewEpisodes: value)

        do {
            let updated = try await settingsClient.updateShowAutoDownloadNewEpisodes(showId: showId, value: value)
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

    // Episode limit and charging-only are set together via one endpoint (#689, mirroring
    // AutoDeleteRule's rule+afterDays bundling), so each binding's setter carries the *other*
    // field's current value along rather than clobbering it.
    private var autoDownloadEpisodeLimitOverrideBinding: Binding<Int?> {
        Binding(
            get: { settings?.autoDownloadEpisodeLimit },
            set: { newValue in
                autoDownloadRulesSaveTask?.cancel()
                autoDownloadRulesSaveTask = Task {
                    await updateAutoDownloadRulesOverride(episodeLimit: newValue, chargingOnly: settings?.autoDownloadChargingOnly)
                }
            }
        )
    }

    private var autoDownloadChargingOnlyOverrideBinding: Binding<Bool?> {
        Binding(
            get: { settings?.autoDownloadChargingOnly },
            set: { newValue in
                autoDownloadRulesSaveTask?.cancel()
                autoDownloadRulesSaveTask = Task {
                    await updateAutoDownloadRulesOverride(episodeLimit: settings?.autoDownloadEpisodeLimit, chargingOnly: newValue)
                }
            }
        )
    }

    private func updateAutoDownloadRulesOverride(episodeLimit: Int?, chargingOnly: Bool?) async {
        guard let previous = settings else { return }

        autoDownloadRulesSaveError = nil
        settings = previous.with(autoDownloadEpisodeLimit: episodeLimit, autoDownloadChargingOnly: chargingOnly)

        do {
            let updated = try await settingsClient.updateShowAutoDownloadRules(
                showId: showId, episodeLimit: episodeLimit, chargingOnly: chargingOnly)
            if !Task.isCancelled {
                settings = updated
                // Otherwise a lowered limit would only take effect the next time this show
                // happens to get a new episode auto-downloaded, which could be days away or
                // never for an inactive show — apply it immediately (#689).
                let effectiveLimit = updated.autoDownloadEpisodeLimit ?? globalAutoDownloadEpisodeLimit
                DownloadManager.shared.enforceEpisodeLimit(showId: showId, limit: effectiveLimit, in: modelContext)
            }
        } catch {
            if !Task.isCancelled {
                settings = previous
                autoDownloadRulesSaveError = "Something went wrong while saving. Please try again."
            }
        }
    }

    private var autoDeleteRuleOverrideBinding: Binding<AutoDeleteRule?> {
        Binding(
            get: { settings?.autoDeleteRule },
            set: { newValue in
                autoDeleteSaveTask?.cancel()
                // Switching to "After N days" with no prior day-count override seeds 7, so the
                // stepper and the persisted override start from a concrete value.
                let afterDays = newValue == .afterDays
                    ? (settings?.autoDeleteAfterDays ?? 7)
                    : settings?.autoDeleteAfterDays
                autoDeleteSaveTask = Task { await updateAutoDeleteOverride(rule: newValue, afterDays: afterDays) }
            }
        )
    }

    private var autoDeleteAfterDaysOverrideBinding: Binding<Int> {
        Binding(
            get: { settings?.autoDeleteAfterDays ?? 7 },
            set: { newValue in
                autoDeleteSaveTask?.cancel()
                autoDeleteSaveTask = Task {
                    await updateAutoDeleteOverride(rule: settings?.autoDeleteRule, afterDays: newValue)
                }
            }
        )
    }

    private func updateAutoDeleteOverride(rule: AutoDeleteRule?, afterDays: Int?) async {
        guard let previous = settings else { return }

        autoDeleteSaveError = nil
        settings = previous.with(autoDeleteRule: rule, autoDeleteAfterDays: afterDays)

        do {
            let updated = try await settingsClient.updateShowAutoDeleteRule(showId: showId, rule: rule, afterDays: afterDays)
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

    private var autoAddUpNextOverrideBinding: Binding<Bool?> {
        Binding(
            get: { settings?.autoAddNewEpisodesToUpNext },
            set: { newValue in
                autoAddUpNextSaveTask?.cancel()
                autoAddUpNextSaveTask = Task { await updateAutoAddUpNextOverride(newValue) }
            }
        )
    }

    private func updateAutoAddUpNextOverride(_ value: Bool?) async {
        guard let previous = settings else { return }

        autoAddUpNextSaveError = nil
        settings = previous.with(autoAddNewEpisodesToUpNext: value)

        do {
            let updated = try await settingsClient.updateShowAutoAddNewEpisodesToUpNext(showId: showId, value: value)
            if !Task.isCancelled {
                settings = updated
            }
        } catch {
            if !Task.isCancelled {
                settings = previous
                autoAddUpNextSaveError = "Something went wrong while saving. Please try again."
            }
        }
    }

    private var upNextInsertPositionOverrideBinding: Binding<UpNextInsertPosition?> {
        Binding(
            get: { settings?.upNextInsertPosition },
            set: { newValue in
                upNextInsertPositionSaveTask?.cancel()
                upNextInsertPositionSaveTask = Task { await updateUpNextInsertPositionOverride(newValue) }
            }
        )
    }

    private func updateUpNextInsertPositionOverride(_ value: UpNextInsertPosition?) async {
        guard let previous = settings else { return }

        upNextInsertPositionSaveError = nil
        settings = previous.with(upNextInsertPosition: value)

        do {
            let updated = try await settingsClient.updateShowUpNextInsertPosition(showId: showId, value: value)
            if !Task.isCancelled {
                settings = updated
            }
        } catch {
            if !Task.isCancelled {
                settings = previous
                upNextInsertPositionSaveError = "Something went wrong while saving. Please try again."
            }
        }
    }

    private var playNextBehaviorOverrideBinding: Binding<PlayNextBehavior?> {
        Binding(
            get: { settings?.playNextBehavior },
            set: { newValue in
                playNextBehaviorSaveTask?.cancel()
                playNextBehaviorSaveTask = Task { await updatePlayNextBehaviorOverride(newValue) }
            }
        )
    }

    private func updatePlayNextBehaviorOverride(_ value: PlayNextBehavior?) async {
        guard let previous = settings else { return }

        playNextBehaviorSaveError = nil
        settings = previous.with(playNextBehavior: value)

        do {
            let updated = try await settingsClient.updateShowPlayNextBehavior(showId: showId, value: value)
            if !Task.isCancelled {
                settings = updated
            }
        } catch {
            if !Task.isCancelled {
                settings = previous
                playNextBehaviorSaveError = "Something went wrong while saving. Please try again."
            }
        }
    }

    private var smartSpeedOverrideBinding: Binding<Bool?> {
        Binding(
            get: { settings?.smartSpeed },
            set: { newValue in
                smartSpeedSaveTask?.cancel()
                smartSpeedSaveTask = Task { await updateSmartSpeedOverride(newValue) }
            }
        )
    }

    private func updateSmartSpeedOverride(_ value: Bool?) async {
        guard let previous = settings else { return }

        smartSpeedSaveError = nil
        settings = previous.with(smartSpeed: value)

        do {
            let updated = try await settingsClient.updateShowSmartSpeed(showId: showId, value: value)
            if !Task.isCancelled {
                settings = updated
            }
        } catch {
            if !Task.isCancelled {
                settings = previous
                smartSpeedSaveError = "Something went wrong while saving. Please try again."
            }
        }
    }

    private var voiceBoostOverrideBinding: Binding<Bool?> {
        Binding(
            get: { settings?.voiceBoost },
            set: { newValue in
                voiceBoostSaveTask?.cancel()
                voiceBoostSaveTask = Task { await updateVoiceBoostOverride(newValue) }
            }
        )
    }

    private func updateVoiceBoostOverride(_ value: Bool?) async {
        guard let previous = settings else { return }

        voiceBoostSaveError = nil
        settings = previous.with(voiceBoost: value)

        do {
            let updated = try await settingsClient.updateShowVoiceBoost(showId: showId, value: value)
            if !Task.isCancelled {
                settings = updated
            }
        } catch {
            if !Task.isCancelled {
                settings = previous
                voiceBoostSaveError = "Something went wrong while saving. Please try again."
            }
        }
    }

    private var trimSilenceOverrideBinding: Binding<Bool?> {
        Binding(
            get: { settings?.trimSilence },
            set: { newValue in
                trimSilenceSaveTask?.cancel()
                trimSilenceSaveTask = Task { await updateTrimSilenceOverride(newValue) }
            }
        )
    }

    private func updateTrimSilenceOverride(_ value: Bool?) async {
        guard let previous = settings else { return }

        trimSilenceSaveError = nil
        settings = previous.with(trimSilence: value)

        do {
            let updated = try await settingsClient.updateShowTrimSilence(showId: showId, value: value)
            if !Task.isCancelled {
                settings = updated
            }
        } catch {
            if !Task.isCancelled {
                settings = previous
                trimSilenceSaveError = "Something went wrong while saving. Please try again."
            }
        }
    }

    private var notificationsEnabledOverrideBinding: Binding<Bool?> {
        Binding(
            get: { settings?.notificationsEnabled },
            set: { newValue in
                notificationsEnabledSaveTask?.cancel()
                notificationsEnabledSaveTask = Task { await updateNotificationsEnabledOverride(newValue) }
            }
        )
    }

    private func updateNotificationsEnabledOverride(_ value: Bool?) async {
        guard let previous = settings else { return }

        notificationsEnabledSaveError = nil
        settings = previous.with(notificationsEnabled: value)

        do {
            let updated = try await settingsClient.updateShowNotificationsEnabled(showId: showId, value: value)
            if !Task.isCancelled {
                settings = updated
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
    ShowSettingsSheet(showId: "preview-show", showTitle: "Preview Show")
}
