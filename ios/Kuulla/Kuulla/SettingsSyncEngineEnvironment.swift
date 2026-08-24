import SwiftUI

// Mirrors EpisodeSyncEngineEnvironment.swift for the settings domain's own SyncEngine instance.
private struct SettingsSyncEngineKey: EnvironmentKey {
    static let defaultValue: SyncEngine<SettingsSyncAdapter>? = nil
}

extension EnvironmentValues {
    var settingsSyncEngine: SyncEngine<SettingsSyncAdapter>? {
        get { self[SettingsSyncEngineKey.self] }
        set { self[SettingsSyncEngineKey.self] = newValue }
    }
}
