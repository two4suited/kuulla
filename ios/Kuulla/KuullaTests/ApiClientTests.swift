import XCTest
@testable import Kuulla

final class ApiClientTests: XCTestCase {
    private var client: ApiClient!

    override func setUp() {
        super.setUp()
        client = ApiClient(baseURL: URL(string: "https://example.com")!, session: MockURLProtocol.makeSession())
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    func testGetDecodesJSONResponse() async throws {
        let json = """
        {"id":"1","userId":"u1","showId":"s1","showTitle":"Title","showAuthor":"Author","showArtworkUrl":null,"subscribedAt":"2024-01-15T10:30:00+00:00"}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 200, data: json, headers: [:])) }

        let subscription: Subscription = try await client.get("api/subscriptions/1")

        XCTAssertEqual(subscription.id, "1")
        XCTAssertEqual(subscription.showTitle, "Title")
    }

    func testGetDecodesDateWithFractionalSeconds() async throws {
        let json = """
        {"id":"1","userId":"u1","showId":"s1","showTitle":"T","showAuthor":"A","showArtworkUrl":null,"subscribedAt":"2024-01-15T10:30:00.123+00:00"}
        """.data(using: .utf8)!
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 200, data: json, headers: [:])) }

        let subscription: Subscription = try await client.get("api/subscriptions/1")

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(subscription.subscribedAt, formatter.date(from: "2024-01-15T10:30:00.123+00:00"))
    }

    func testGetEncodesLiteralPlusInQueryValues() async throws {
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 200, data: "[]".data(using: .utf8)!, headers: [:])) }

        let _: [Show] = try await client.get("api/shows/search", queryItems: [URLQueryItem(name: "q", value: "C++")])

        let requestedURL = try XCTUnwrap(MockURLProtocol.requestedURLs.first)
        let components = URLComponents(url: requestedURL, resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.percentEncodedQuery, "q=C%2B%2B")
    }

    func testGetThrowsRequestFailedForNon2xxStatus() async {
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 404, data: Data(), headers: [:])) }

        do {
            let _: Show = try await client.get("api/shows/missing")
            XCTFail("expected ApiError.requestFailed")
        } catch ApiError.requestFailed(let statusCode) {
            XCTAssertEqual(statusCode, 404)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testPostSendsBodyAndDecodesResponse() async throws {
        struct Body: Encodable { let showId: String }
        let json = """
        {"id":"1","userId":"u1","showId":"s1","showTitle":"T","showAuthor":"A","showArtworkUrl":null,"subscribedAt":"2024-01-15T10:30:00+00:00"}
        """.data(using: .utf8)!
        var capturedBody: Data?
        MockURLProtocol.stubHandler = { request in
            capturedBody = request.httpBody ?? request.httpBodyStream.flatMap { stream -> Data? in
                stream.open()
                defer { stream.close() }
                var data = Data()
                let bufferSize = 1024
                var buffer = [UInt8](repeating: 0, count: bufferSize)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: bufferSize)
                    if read > 0 { data.append(buffer, count: read) }
                }
                return data
            }
            return .success(.init(statusCode: 201, data: json, headers: [:]))
        }

        let subscription: Subscription = try await client.post("api/subscriptions", body: Body(showId: "s1"))

        XCTAssertEqual(subscription.showId, "s1")
        let decodedBody = try XCTUnwrap(capturedBody)
        let bodyJSON = try JSONSerialization.jsonObject(with: decodedBody) as? [String: String]
        XCTAssertEqual(bodyJSON?["showId"], "s1")
    }

    func testDeleteSucceedsOn2xxEmptyResponse() async throws {
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 204, data: Data(), headers: [:])) }

        try await client.delete("api/subscriptions/s1")
    }

    func testDeleteThrowsOnNon2xxStatus() async {
        MockURLProtocol.stubHandler = { _ in .success(.init(statusCode: 500, data: Data(), headers: [:])) }

        do {
            try await client.delete("api/subscriptions/s1")
            XCTFail("expected ApiError.requestFailed")
        } catch ApiError.requestFailed(let statusCode) {
            XCTAssertEqual(statusCode, 500)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
