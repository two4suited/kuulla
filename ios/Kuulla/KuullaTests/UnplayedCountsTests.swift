import XCTest
@testable import Kuulla

final class UnplayedCountsTests: XCTestCase {
    func testGroupsShowIdsByCount() {
        let counts = UnplayedCounts.compute(from: ["show-1", "show-1", "show-2"])

        XCTAssertEqual(counts["show-1"], 2)
        XCTAssertEqual(counts["show-2"], 1)
    }

    func testEmptyInputReturnsEmptyDictionary() {
        XCTAssertTrue(UnplayedCounts.compute(from: []).isEmpty)
    }

    func testShowWithNoEpisodesIsAbsentFromResult() {
        let counts = UnplayedCounts.compute(from: ["show-1"])

        XCTAssertNil(counts["show-2"])
    }
}
