import XCTest
@testable import Kuulla

final class EpisodeDecodingTests: XCTestCase {
    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(text)")
            }
            return date
        }
        return decoder
    }

    func testDecodesEpisodeWithDurationAndPublishedAt() throws {
        let json = """
        {
            "id": "e1",
            "showId": "s1",
            "title": "Episode 1",
            "publishedAt": "2024-01-15T10:30:00+00:00",
            "duration": "01:02:03",
            "audioUrl": "https://example.com/audio.mp3",
            "description": "desc",
            "bitrateKbps": 128,
            "fileSizeBytes": 1000
        }
        """.data(using: .utf8)!

        let episode = try makeDecoder().decode(Episode.self, from: json)

        XCTAssertEqual(episode.id, "e1")
        XCTAssertEqual(episode.duration, 3723)
        XCTAssertNotNil(episode.publishedAt)
        XCTAssertEqual(episode.bitrateKbps, 128)
    }

    func testDecodesEpisodeWithMissingOptionalFields() throws {
        let json = """
        {
            "id": "e1",
            "showId": "s1",
            "title": "Episode 1",
            "audioUrl": "https://example.com/audio.mp3"
        }
        """.data(using: .utf8)!

        let episode = try JSONDecoder().decode(Episode.self, from: json)

        XCTAssertNil(episode.publishedAt)
        XCTAssertNil(episode.duration)
        XCTAssertNil(episode.description)
        XCTAssertNil(episode.bitrateKbps)
        XCTAssertNil(episode.fileSizeBytes)
    }
}
