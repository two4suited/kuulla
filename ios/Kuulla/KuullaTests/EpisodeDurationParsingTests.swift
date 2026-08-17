import XCTest
@testable import Kuulla

final class EpisodeDurationParsingTests: XCTestCase {
    func testParsesHoursMinutesSeconds() {
        XCTAssertEqual(Episode.parseDuration("01:02:03"), 3723)
    }

    func testParsesMinutesSeconds() {
        XCTAssertEqual(Episode.parseDuration("45:00"), 2700)
    }

    func testParsesDaysPrefix() {
        XCTAssertEqual(Episode.parseDuration("1.02:03:04"), 93784)
    }

    func testParsesFractionalSeconds() {
        XCTAssertEqual(Episode.parseDuration("00:45:00.500"), 2700.5)
    }

    func testParsesNegativeDuration() {
        XCTAssertEqual(Episode.parseDuration("-00:45:00"), -2700)
    }

    func testReturnsNilForInvalidFormat() {
        XCTAssertNil(Episode.parseDuration("not-a-duration"))
    }

    func testReturnsNilForEmptyString() {
        XCTAssertNil(Episode.parseDuration(""))
    }
}
