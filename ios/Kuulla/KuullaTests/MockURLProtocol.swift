import Foundation
import XCTest
@testable import Kuulla

// Intercepts URLSession requests in tests so ApiClient and its callers can be
// exercised without hitting a live API.
final class MockURLProtocol: URLProtocol {
    struct Stub {
        let statusCode: Int
        let data: Data
        let headers: [String: String]
    }

    // Guards the two properties below: URLProtocol callbacks can run off the main thread, and
    // XCTest could in principle run test methods concurrently, so plain globals would race.
    private static let stateLock = NSLock()
    private nonisolated(unsafe) static var _stubHandler: ((URLRequest) -> Result<Stub, Error>)?
    private nonisolated(unsafe) static var _requestedURLs: [URL] = []

    static var stubHandler: ((URLRequest) -> Result<Stub, Error>)? {
        get { stateLock.withLock { _stubHandler } }
        set { stateLock.withLock { _stubHandler = newValue } }
    }

    static var requestedURLs: [URL] {
        stateLock.withLock { _requestedURLs }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.stateLock.withLock { Self._requestedURLs.append(url) }
        guard let handler = Self.stubHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        switch handler(request) {
        case .success(let stub):
            let response = HTTPURLResponse(
                url: url,
                statusCode: stub.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: stub.headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func reset() {
        stateLock.withLock {
            _stubHandler = nil
            _requestedURLs = []
        }
    }
}

// Shared setUp/tearDown for test classes that exercise ApiClient (and its PodcastCatalogClient /
// SubscriptionClient wrappers) against a mocked network layer, so each subclass can't forget to
// reset MockURLProtocol's shared state between tests.
class MockedApiTestCase: XCTestCase {
    let apiClient = ApiClient(baseURL: URL(string: "https://example.com")!, session: MockURLProtocol.makeSession())

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }
}

extension URLRequest {
    // URLSession moves a request's httpBody into httpBodyStream before handing it to a
    // URLProtocol, so a mock reading the body back out (to assert what was sent) needs to drain
    // the stream rather than read httpBody directly.
    var capturedBodyData: Data? {
        if let httpBody {
            return httpBody
        }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
