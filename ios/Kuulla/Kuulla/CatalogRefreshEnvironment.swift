import SwiftUI

// Mirrors PlaylistSyncEngineEnvironment.swift: KuullaApp owns the single CatalogRefreshService
// (it shares the app's ModelContainer) and publishes it here so Library, Subscriptions,
// ShowDetail and Settings can reach it without threading it through every init.
private struct CatalogRefreshKey: EnvironmentKey {
    static let defaultValue: CatalogRefreshService? = nil
}

extension EnvironmentValues {
    var catalogRefresh: CatalogRefreshService? {
        get { self[CatalogRefreshKey.self] }
        set { self[CatalogRefreshKey.self] = newValue }
    }
}
