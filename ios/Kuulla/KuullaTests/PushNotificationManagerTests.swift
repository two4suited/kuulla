import XCTest
import UserNotifications
@testable import Kuulla

final class MockNotificationAuthorizing: NotificationAuthorizing {
    var requestAuthorizationResult: Result<Bool, Error> = .success(true)
    var authorizationStatus: UNAuthorizationStatus = .authorized

    func requestAuthorization() async throws -> Bool {
        try requestAuthorizationResult.get()
    }

    func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        authorizationStatus
    }
}

final class PushNotificationManagerTests: MockedApiTestCase {
    private var deviceTokenClient: DeviceTokenClient { DeviceTokenClient(apiClient: apiClient) }

    func testHandleDeviceTokenRegistersWithApi() async throws {
        let json = """
        {"id":"u1:d1","userId":"u1","deviceId":"d1","apnsToken":"tok","platform":0,"updatedAt":"2024-01-15T10:30:00+00:00"}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 200, data: json, headers: [:])) }
        let sut = PushNotificationManager(deviceTokenClient: deviceTokenClient, authorizing: MockNotificationAuthorizing())

        await sut.handleDeviceToken("apns-token-hex")

        let requestedURL = try XCTUnwrap(MockURLProtocol.requestedURLs.first)
        XCTAssertTrue(requestedURL.absoluteString.hasSuffix("/api/notifications/device-token"))
    }

    func testSyncAuthorizationStatusUnregistersWhenDenied() async throws {
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 204, data: Data(), headers: [:])) }
        let authorizing = MockNotificationAuthorizing()
        authorizing.authorizationStatus = .denied
        let sut = PushNotificationManager(deviceTokenClient: deviceTokenClient, authorizing: authorizing)

        await sut.syncAuthorizationStatus()

        let requestedURL = try XCTUnwrap(MockURLProtocol.requestedURLs.first)
        XCTAssertTrue(requestedURL.absoluteString.contains("/api/notifications/device-token/"))
    }

    func testSyncAuthorizationStatusDoesNothingWhenAuthorized() async {
        let authorizing = MockNotificationAuthorizing()
        authorizing.authorizationStatus = .authorized
        let sut = PushNotificationManager(deviceTokenClient: deviceTokenClient, authorizing: authorizing)

        await sut.syncAuthorizationStatus()

        XCTAssertTrue(MockURLProtocol.requestedURLs.isEmpty)
    }

    func testSyncAuthorizationStatusDoesNothingWhenNotDetermined() async {
        // .notDetermined means the user hasn't been asked yet (or the system prompt is still
        // pending) — treating it as "revoked" would unregister a device that was never actually
        // registered, and could race the very first requestAuthorizationAndRegister() call.
        let authorizing = MockNotificationAuthorizing()
        authorizing.authorizationStatus = .notDetermined
        let sut = PushNotificationManager(deviceTokenClient: deviceTokenClient, authorizing: authorizing)

        await sut.syncAuthorizationStatus()

        XCTAssertTrue(MockURLProtocol.requestedURLs.isEmpty)
    }

    func testUnregisterCurrentDeviceCallsApi() async throws {
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 204, data: Data(), headers: [:])) }
        let sut = PushNotificationManager(deviceTokenClient: deviceTokenClient, authorizing: MockNotificationAuthorizing())

        await sut.unregisterCurrentDevice()

        XCTAssertEqual(MockURLProtocol.requestedURLs.count, 1)
    }

    func testRequestAuthorizationAndRegisterDoesNothingWhenDenied() async {
        // Doesn't touch the network at all when the user declines the permission prompt — no
        // device token to register, and UIApplication.shared.registerForRemoteNotifications()
        // shouldn't be called either (asking the OS for a token it won't deliver).
        let authorizing = MockNotificationAuthorizing()
        authorizing.requestAuthorizationResult = .success(false)
        let sut = PushNotificationManager(deviceTokenClient: deviceTokenClient, authorizing: authorizing)

        await sut.requestAuthorizationAndRegister()

        XCTAssertTrue(MockURLProtocol.requestedURLs.isEmpty)
    }
}
