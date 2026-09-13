import UIKit

// Abstracts UIDevice's battery state so FeedView's "charging only" auto-download rule (#689) is
// testable without depending on the simulator/device's real, non-deterministic battery state —
// mirrors DownloadManager's NetworkPathObserving seam for the same reason.
protocol DeviceChargingStateProviding {
    var isCharging: Bool { get }
}

struct UIDeviceChargingStateProvider: DeviceChargingStateProviding {
    var isCharging: Bool {
        UIDevice.current.isBatteryMonitoringEnabled = true
        // .full counts as charging too — a fully-charged, still-plugged-in phone is exactly the
        // "not draining the battery for this" situation the setting is meant to allow.
        return UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
    }
}
