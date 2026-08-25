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

    func testSyncAuthorizationStatusReRegistersWhenAlreadyAuthorized() async {
        // Doesn't hit the network client directly (registerForRemoteNotifications() is a live
        // UIApplication call, not routed through MockURLProtocol) — this just proves the
        // .authorized branch doesn't call unregister, unlike .denied. The actual re-registration
        // effect (a fresh handleDeviceToken() call once APNs responds) is covered by
        // testHandleDeviceTokenRegistersWithApi.
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

    func testHandleDeviceTokenUndoesRegistrationWhenSignOutRacesIt() async throws {
        // Simulates a sign-out's unregisterCurrentDevice() bumping registrationEpoch while this
        // register() call is still in flight — the epoch bump happens synchronously inside the
        // stub handler, which runs strictly before the response is delivered back to
        // handleDeviceToken's awaiting coroutine, so this deterministically reproduces "sign-out
        // raced an in-flight registration" without relying on real Task scheduling order. Without
        // the epoch check, the device would stay registered to an account the app has since
        // signed out of.
        let registerJson = """
        {"id":"u1:d1","userId":"u1","deviceId":"d1","apnsToken":"tok","platform":0,"updatedAt":"2024-01-15T10:30:00+00:00"}
        """.data(using: .utf8)!
        let sut = PushNotificationManager(deviceTokenClient: deviceTokenClient, authorizing: MockNotificationAuthorizing())
        var requestMethods: [String] = []
        MockURLProtocol.stubHandler = { request in
            requestMethods.append(request.httpMethod ?? "")
            if request.httpMethod == "POST" {
                sut.registrationEpoch += 1
            }
            return .success(.init(statusCode: 200, data: registerJson, headers: [:]))
        }

        await sut.handleDeviceToken("apns-token-hex")

        XCTAssertEqual(requestMethods, ["POST", "DELETE"])
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
