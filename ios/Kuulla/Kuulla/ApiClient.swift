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
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !queryItems.isEmpty {
            components?.queryItems = queryItems
        }
        guard let url = components?.url else {
            throw ApiError.requestFailed(statusCode: nil)
        }

        var request = URLRequest(url: url)
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

        return try Self.decoder.decode(T.self, from: data)
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
}

extension ApiClient {
    static let shared = ApiClient(baseURL: ApiConfiguration.baseURL)
}

enum ApiConfiguration {
    // Aspire assigns the API a random local port on every `aspire start`/`aspire run`
    // (see AuthManager's localTestApiBaseURL), so this resolves the same way: an
    // explicit override, falling back to the port in Kuulla.Api's launchSettings.json
    // http profile, which is only correct when the API is run directly (`dotnet run`).
    static var baseURL: URL {
        if let override = ProcessInfo.processInfo.environment["KUULLA_API_BASE_URL"],
           let url = URL(string: override) {
            return url
        }
        return URL(string: "http://localhost:5245")!
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
