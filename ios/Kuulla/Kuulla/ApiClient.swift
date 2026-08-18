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

    func get<T: Decodable>(_ pathComponents: [String], queryItems: [URLQueryItem] = []) async throws -> T {
        guard var components = Self.components(baseURL: baseURL, pathComponents: pathComponents) else {
            throw ApiError.requestFailed(statusCode: nil)
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
            // URLComponents treats "+" as a legal, unescaped query character, but ASP.NET Core's
            // query parser decodes unescaped "+" as a space — so a literal "+" in a query value
            // (e.g. searching "C++") would silently arrive at the API as a space.
            if let encodedQuery = components.percentEncodedQuery {
                components.percentEncodedQuery = encodedQuery.replacingOccurrences(of: "+", with: "%2B")
            }
        }
        guard let url = components.url else {
            throw ApiError.requestFailed(statusCode: nil)
        }

        let (data, _) = try await send(URLRequest(url: url))
        return try Self.decoder.decode(T.self, from: data)
    }

    func post<T: Decodable>(_ pathComponents: [String], body: some Encodable) async throws -> T {
        try await mutate(pathComponents, body: body, httpMethod: "POST")
    }

    func put<T: Decodable>(_ pathComponents: [String], body: some Encodable) async throws -> T {
        try await mutate(pathComponents, body: body, httpMethod: "PUT")
    }

    private func mutate<T: Decodable>(
        _ pathComponents: [String], body: some Encodable, httpMethod: String
    ) async throws -> T {
        guard let url = Self.components(baseURL: baseURL, pathComponents: pathComponents)?.url else {
            throw ApiError.requestFailed(statusCode: nil)
        }
        var request = URLRequest(url: url)
        request.httpMethod = httpMethod
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.bodyEncoder.encode(body)

        let (data, _) = try await send(request)
        return try Self.decoder.decode(T.self, from: data)
    }

    func delete(_ pathComponents: [String]) async throws {
        guard let url = Self.components(baseURL: baseURL, pathComponents: pathComponents)?.url else {
            throw ApiError.requestFailed(statusCode: nil)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        _ = try await send(request)
    }

    // Callers pass each dynamic segment (e.g. a show or episode id) as its own array element
    // rather than interpolating it into a path string, so escaping can happen once, here, instead
    // of every call site being responsible for it. Each component is percent-encoded individually
    // — including "/" — so a raw "/" inside an id's value can never be mistaken for a path
    // separator (URL.appendingPathComponent could crash-free but silently misroute in that case,
    // and interpolating a pre-escaped segment into a plain path string double-encodes it, e.g.
    // "a%2Fb" becoming "a%252Fb").
    private static func components(baseURL: URL, pathComponents: [String]) -> URLComponents? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let encodedSegments = pathComponents.map {
            $0.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowedCharacters) ?? $0
        }
        let existingPath = components.percentEncodedPath
        let basePath = existingPath.hasSuffix("/") ? String(existingPath.dropLast()) : existingPath
        components.percentEncodedPath = basePath + "/" + encodedSegments.joined(separator: "/")
        return components
    }

    private static let pathSegmentAllowedCharacters = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))

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

    // Mirrors `decoder`'s date handling so round-tripping a value the client itself produced
    // (e.g. a locally-stamped `updatedAt` sent up for sync reconciliation) survives encode/decode
    // without drift, and so .NET's DateTimeOffset model binder — which expects ISO 8601 — accepts it.
    private static let bodyEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ApiDateParsing.string(from: date))
        }
        return encoder
    }()
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

    static func string(from date: Date) -> String {
        withFractionalSeconds.string(from: date)
    }
}

enum ApiError: Error {
    case requestFailed(statusCode: Int?)
}
