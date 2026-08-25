import XCTest
@testable import Kuulla

final class DeviceTokenClientTests: MockedApiTestCase {
    private var client: DeviceTokenClient { DeviceTokenClient(apiClient: apiClient) }

    func testRegisterSendsDeviceIdApnsTokenAndPlatform() async throws {
        let json = """
        {"id":"u1:d1","userId":"u1","deviceId":"d1","apnsToken":"tok","platform":0,"updatedAt":"2024-01-15T10:30:00+00:00"}
        """.data(using: .utf8)!
        var capturedBody: [String: Any]?
        MockURLProtocol.stubHandler = { request in
            if let data = request.capturedBodyData {
                capturedBody = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            return .success(.init(statusCode: 200, data: json, headers: [:]))
        }

        try await client.register(deviceId: "d1", apnsToken: "tok")

        let requestedURL = try XCTUnwrap(MockURLProtocol.requestedURLs.first)
        XCTAssertTrue(requestedURL.absoluteString.hasSuffix("/api/notifications/device-token"))
        let body = try XCTUnwrap(capturedBody)
        XCTAssertEqual(body["deviceId"] as? String, "d1")
        XCTAssertEqual(body["apnsToken"] as? String, "tok")
        // Platform serializes as its raw Int (0 = ios), matching the API's DevicePlatform enum
        // (System.Text.Json default, no string-enum converter configured server-side).
        XCTAssertEqual(body["platform"] as? Int, 0)
    }

    func testRegisterPropagatesFailure() async {
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 500, data: Data(), headers: [:])) }

        do {
            try await client.register(deviceId: "d1", apnsToken: "tok")
            XCTFail("expected ApiError.requestFailed")
        } catch ApiError.requestFailed(let statusCode) {
            XCTAssertEqual(statusCode, 500)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testUnregisterEscapesDeviceIdAndUsesDeleteMethod() async throws {
        var capturedMethod: String?
        MockURLProtocol.stubHandler = { request in
            capturedMethod = request.httpMethod
            return .success(.init(statusCode: 204, data: Data(), headers: [:]))
        }

        try await client.unregister(deviceId: "a/b")

        let requestedURL = try XCTUnwrap(MockURLProtocol.requestedURLs.first)
        XCTAssertTrue(requestedURL.absoluteString.contains("/api/notifications/device-token/a%2Fb"))
        XCTAssertEqual(capturedMethod, "DELETE")
    }
}
