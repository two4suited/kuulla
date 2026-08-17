import Foundation

actor ApiClient {
    private let baseURL: URL
    private let session: URLSession
    private let authManager: AuthManager

    init(baseURL: URL, session: URLSession = .shared, authManager: AuthManager = .shared) {
        self.baseURL = baseURL
        self.session = session
        self.authManager = authManager
    }

    func get<T: Decodable>(_ path: String, queryItems: [URLQueryItem] = []) async throws -> T {
        var components = URLComponents(url: Self.url(baseURL: baseURL, path: path), resolvingAgainstBaseURL: false)
        if !queryItems.isEmpty {
            components?.queryItems = queryItems
            // URLComponents treats "+" as a legal, unescaped query character, but ASP.NET Core's
            // query parser decodes unescaped "+" as a space — so a literal "+" in a query value
            // (e.g. searching "C++") would silently arrive at the API as a space.
            if let encodedQuery = components?.percentEncodedQuery {
                components?.percentEncodedQuery = encodedQuery.replacingOccurrences(of: "+", with: "%2B")
            }
        }
        guard let url = components?.url else {
            throw ApiError.requestFailed(statusCode: nil)
        }

        let (data, _) = try await send(URLRequest(url: url))
        return try Self.decoder.decode(T.self, from: data)
    }

    func post<T: Decodable>(_ path: String, body: some Encodable) async throws -> T {
        var request = URLRequest(url: Self.url(baseURL: baseURL, path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.bodyEncoder.encode(body)

        let (data, _) = try await send(request)
        return try Self.decoder.decode(T.self, from: data)
    }

    func delete(_ path: String) async throws {
        var request = URLRequest(url: Self.url(baseURL: baseURL, path: path))
        request.httpMethod = "DELETE"
        _ = try await send(request)
    }

    // URL.appendingPathComponent treats its argument as literal characters and percent-encodes
    // "%" itself, so an already-escaped segment (e.g. SubscriptionClient's slash-escaped showId)
    // would come out double-encoded ("a%2Fb" -> "a%252Fb"). Building the URL through
    // percentEncodedPath instead preserves any pre-escaped characters in `path` as-is.
    private static func url(baseURL: URL, path: String) -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return baseURL.appendingPathComponent(path)
        }
        let existingPath = components.percentEncodedPath
        let separator = existingPath.hasSuffix("/") || path.hasPrefix("/") ? "" : "/"
        components.percentEncodedPath = existingPath + separator + path
        return components.url ?? baseURL.appendingPathComponent(path)
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        if let idToken = try? await authManager.validIdToken() {
            request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ApiError.requestFailed(statusCode: nil)
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw ApiError.requestFailed(statusCode: httpResponse.statusCode)
        }

        return (data, httpResponse)
    }

    // The API serializes dates as .NET's DateTimeOffset "O" format, e.g.
    // "2024-01-15T10:30:00+00:00" or "2024-01-15T10:30:00.123+00:00" — always an
    // explicit numeric offset, never "Z", and milliseconds only when non-zero.
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = ApiDateParsing.date(from: text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(text)")
            }
            return date
        }
        return decoder
    }()

    private static let bodyEncoder = JSONEncoder()
}

extension ApiClient {
    static let shared = ApiClient(baseURL: ApiConfiguration.baseURL)
}

enum ApiConfiguration {
    static var baseURL: URL {
#if DEBUG
        // Aspire assigns the API a random local port on every `aspire start`/`aspire run`
        // (see AuthManager's localTestApiBaseURL), so this resolves the same way: an
        // explicit override, falling back to the port in Kuulla.Api's launchSettings.json
        // http profile, which is only correct when the API is run directly (`dotnet run`).
        if let override = ProcessInfo.processInfo.environment["KUULLA_API_BASE_URL"],
           let url = URL(string: override) {
            return url
        }
        return URL(string: "http://localhost:5245")!
#else
        fatalError("ApiConfiguration.baseURL needs a production API URL configured before Release builds can run.")
#endif
    }
}

private enum ApiDateParsing {
    private static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let withoutFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func date(from text: String) -> Date? {
        withFractionalSeconds.date(from: text) ?? withoutFractionalSeconds.date(from: text)
    }
}

enum ApiError: Error {
    case requestFailed(statusCode: Int?)
}
