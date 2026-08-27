import XCTest
@testable import Kuulla

final class ChapterScrubberTests: XCTestCase {
    private func makeChapter(startTime: TimeInterval, title: String, url: String? = nil) -> EpisodeChapter {
        let urlJson = url.map { "\"\($0)\"" } ?? "null"
        let json = """
        { "startTime": "\(Self.formatSeconds(startTime))", "title": "\(title)", "imageUrl": null, "url": \(urlJson) }
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

    func testActiveChapterIndexIsCorrectWhenChaptersAreOutOfOrder() {
        // The feed's own chapter JSON order is preserved as-is, not guaranteed sorted by
        // startTime — activeChapterIndex must still pick the greatest eligible startTime, not
        // just the last matching array index.
        let chapters = [
            makeChapter(startTime: 300, title: "Segment 2"),
            makeChapter(startTime: 0, title: "Intro"),
            makeChapter(startTime: 60, title: "Segment 1"),
        ]

        XCTAssertEqual(ChapterScrubber.activeChapterIndex(chapters: chapters, currentTime: 0), 1)
        XCTAssertEqual(ChapterScrubber.activeChapterIndex(chapters: chapters, currentTime: 59), 1)
        XCTAssertEqual(ChapterScrubber.activeChapterIndex(chapters: chapters, currentTime: 60), 2)
        XCTAssertEqual(ChapterScrubber.activeChapterIndex(chapters: chapters, currentTime: 301), 0)
    }

    func testTickOffsetScalesWithinTrack() {
        XCTAssertEqual(ChapterScrubber.tickOffset(startTime: 0, duration: 100, trackWidth: 200), 0)
        XCTAssertEqual(ChapterScrubber.tickOffset(startTime: 50, duration: 100, trackWidth: 200), 100)
    }

    func testTickOffsetClampsEndOfEpisodeChapterToStayOnScreen() {
        // startTime == duration would otherwise land exactly at trackWidth, pushing the
        // tickWidth-wide tick fully off the visible track.

        let offset = ChapterScrubber.tickOffset(startTime: 100, duration: 100, trackWidth: 200)

        XCTAssertEqual(offset, 200 - ChapterScrubber.tickWidth)
    }

    func testTickOffsetClampsStartTimeBeyondDuration() {
        let offset = ChapterScrubber.tickOffset(startTime: 1000, duration: 100, trackWidth: 200)

        XCTAssertEqual(offset, 200 - ChapterScrubber.tickWidth)
    }

    func testTickOffsetClampsNegativeStartTime() {
        XCTAssertEqual(ChapterScrubber.tickOffset(startTime: -10, duration: 100, trackWidth: 200), 0)
    }

    func testTickOffsetDoesNotGoNegativeWhenTrackNarrowerThanTick() {
        // trackWidth - tickWidth would be negative here without the extra max(..., 0) clamp on
        // the upper bound itself.
        XCTAssertEqual(ChapterScrubber.tickOffset(startTime: 0, duration: 100, trackWidth: 1), 0)
        XCTAssertEqual(ChapterScrubber.tickOffset(startTime: 50, duration: 100, trackWidth: 1), 0)
    }

    func testTapActionSeeksWhenChapterIsNotActive() {
        let chapter = makeChapter(startTime: 60, title: "Segment 1", url: "https://sponsor.example")

        XCTAssertEqual(ChapterScrubber.tapAction(for: chapter, isActive: false), .seek(60))
    }

    func testTapActionSeeksWhenActiveChapterHasNoUrl() {
        let chapter = makeChapter(startTime: 60, title: "Segment 1")

        XCTAssertEqual(ChapterScrubber.tapAction(for: chapter, isActive: true), .seek(60))
    }

    func testTapActionOpensLinkWhenActiveChapterHasUrl() {
        let chapter = makeChapter(startTime: 60, title: "Segment 1", url: "https://sponsor.example")

        XCTAssertEqual(ChapterScrubber.tapAction(for: chapter, isActive: true), .openLink(URL(string: "https://sponsor.example")!))
    }

    func testTapActionSeeksWhenActiveChapterUrlIsNotHttpOrHttps() {
        let chapter = makeChapter(startTime: 60, title: "Segment 1", url: "mailto:sponsor@example.com")

        XCTAssertEqual(ChapterScrubber.tapAction(for: chapter, isActive: true), .seek(60))
    }

    func testTapActionAccessibilityHintDistinguishesSeekFromOpenLink() {
        XCTAssertEqual(ChapterScrubber.TapAction.seek(60).accessibilityHint, "Seeks to this chapter.")
        XCTAssertEqual(
            ChapterScrubber.TapAction.openLink(URL(string: "https://sponsor.example")!).accessibilityHint,
            "Opens this chapter's link.")
    }
}
