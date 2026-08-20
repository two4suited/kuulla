import XCTest
@testable import Kuulla

final class EpisodeProgressTests: XCTestCase {
    func testReturnsNilForZeroPosition() {
        XCTAssertNil(EpisodeProgress.fraction(positionSeconds: 0, duration: 1200))
    }

    func testReturnsNilForMissingDuration() {
        XCTAssertNil(EpisodeProgress.fraction(positionSeconds: 300, duration: nil))
    }

    func testReturnsNilForZeroDuration() {
        XCTAssertNil(EpisodeProgress.fraction(positionSeconds: 300, duration: 0))
    }

    func testComputesFractionForNormalCase() {
        let fraction = EpisodeProgress.fraction(positionSeconds: 300, duration: 1200)
        XCTAssertEqual(fraction!, 0.25, accuracy: 0.0001)
    }

    func testClampsNearCompleteEpisodeBelowOne() {
        let fraction = EpisodeProgress.fraction(positionSeconds: 1190, duration: 1200)
        XCTAssertEqual(fraction!, 0.99, accuracy: 0.0001)
    }

    func testClampsJustStartedEpisodeAboveZero() {
        let fraction = EpisodeProgress.fraction(positionSeconds: 1, duration: 1200)
        XCTAssertEqual(fraction!, 0.01, accuracy: 0.0001)
    }
}
