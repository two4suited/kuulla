import Foundation

struct DeviceTokenClient {
    private let apiClient: ApiClient

    init(apiClient: ApiClient = .shared) {
        self.apiClient = apiClient
    }

    // Register/refresh — POST is idempotent server-side (upserts on the composite
    // (userId, deviceId) id), so this is safe to call again with a reissued APNs token.
    func register(deviceId: String, apnsToken: String) async throws {
        let _: DeviceTokenResponse = try await apiClient.post(
            ["api", "notifications", "device-token"],
            body: RegisterDeviceTokenRequest(deviceId: deviceId, apnsToken: apnsToken, platform: .ios))
    }

    func unregister(deviceId: String) async throws {
        try await apiClient.delete(["api", "notifications", "device-token", deviceId])
    }
}

private struct RegisterDeviceTokenRequest: Encodable {
    let deviceId: String
    let apnsToken: String
    let platform: DevicePlatform
}

// Matches the API's DevicePlatform enum, which System.Text.Json serializes as its raw int value
// (no string-enum converter configured server-side) — Ios = 0.
private enum DevicePlatform: Int, Encodable {
    case ios = 0
}

// Only used to confirm the POST decoded successfully — no field is read.
private struct DeviceTokenResponse: Decodable {
    let id: String
}
