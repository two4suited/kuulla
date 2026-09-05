import XCTest
@testable import Kuulla

final class ShowIconSizeTests: XCTestCase {
    func testDefaultIsLarge() {
        XCTAssertEqual(ShowIconSize.default, .large)
    }

    func testLargeKeepsOriginalGridMinimum() {
        // The layout that shipped before this option existed used minimum: 110.
        XCTAssertEqual(ShowIconSize.large.gridMinimum, 110)
    }

    func testGridMinimumIncreasesWithSize() {
        XCTAssertLessThan(ShowIconSize.small.gridMinimum, ShowIconSize.medium.gridMinimum)
        XCTAssertLessThan(ShowIconSize.medium.gridMinimum, ShowIconSize.large.gridMinimum)
    }

    func testCurrentFallsBackToDefaultForUnknownRawValue() {
        XCTAssertEqual(ShowIconSize.current("gigantic"), .default)
    }

    func testCurrentRoundTripsKnownRawValues() {
        for size in ShowIconSize.allCases {
            XCTAssertEqual(ShowIconSize.current(size.rawValue), size)
        }
    }
}
