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

    func get<T: Decodable>(_ path: String) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        if let idToken = try? await authManager.validIdToken() {
            request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw ApiError.requestFailed
        }

        return try JSONDecoder().decode(T.self, from: data)
    }
}

enum ApiError: Error {
    case requestFailed
}
