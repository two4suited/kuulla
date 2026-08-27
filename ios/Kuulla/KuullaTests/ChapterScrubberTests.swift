import XCTest
@testable import Kuulla

final class ChapterScrubberTests: XCTestCase {
    private func makeChapter(startTime: TimeInterval, title: String) -> EpisodeChapter {
        let json = """
        { "startTime": "\(Self.formatSeconds(startTime))", "title": "\(title)", "imageUrl": null, "url": null }
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(EpisodeChapter.self, from: json)
    }

    private static func formatSeconds(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    func testActiveChapterIndexReturnsNilWhenNoChapters() {
        XCTAssertNil(ChapterScrubber.activeChapterIndex(chapters: [], currentTime: 10))
    }

    func testActiveChapterIndexReturnsNilBeforeFirstChapter() {
        let chapters = [makeChapter(startTime: 10, title: "Intro")]
        XCTAssertNil(ChapterScrubber.activeChapterIndex(chapters: chapters, currentTime: 5))
    }

    func testActiveChapterIndexReturnsLastChapterReached() {
        let chapters = [
            makeChapter(startTime: 0, title: "Intro"),
            makeChapter(startTime: 60, title: "Segment 1"),
            makeChapter(startTime: 300, title: "Segment 2"),
        ]

        XCTAssertEqual(ChapterScrubber.activeChapterIndex(chapters: chapters, currentTime: 0), 0)
        XCTAssertEqual(ChapterScrubber.activeChapterIndex(chapters: chapters, currentTime: 59), 0)
        XCTAssertEqual(ChapterScrubber.activeChapterIndex(chapters: chapters, currentTime: 60), 1)
        XCTAssertEqual(ChapterScrubber.activeChapterIndex(chapters: chapters, currentTime: 301), 2)
    }
}
