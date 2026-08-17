import XCTest
@testable import Kuulla

final class EpisodeFormattingTests: XCTestCase {
    func testFormatsUnderHourAsMinutesSeconds() {
        XCTAssertEqual(EpisodeFormatting.formatDuration(125), "2:05")
    }

    func testFormatsOverHourAsHoursMinutesSeconds() {
        XCTAssertEqual(EpisodeFormatting.formatDuration(3725), "1:02:05")
    }

    func testRoundsFractionalSeconds() {
        XCTAssertEqual(EpisodeFormatting.formatDuration(59.6), "1:00")
    }

    func testFormatsZero() {
        XCTAssertEqual(EpisodeFormatting.formatDuration(0), "0:00")
    }
}
