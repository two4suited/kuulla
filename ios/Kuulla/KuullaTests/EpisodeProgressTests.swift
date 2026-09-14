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

    // MARK: - isNearEnd (#704)

    func testIsNearEndFalseWhenWellBeforeThreshold() {
        XCTAssertFalse(EpisodeProgress.isNearEnd(positionSeconds: 1000, duration: 1200, thresholdSeconds: 30))
    }

    func testIsNearEndTrueAtExactBoundary() {
        XCTAssertTrue(EpisodeProgress.isNearEnd(positionSeconds: 1170, duration: 1200, thresholdSeconds: 30))
    }

    func testIsNearEndTrueWithinThreshold() {
        XCTAssertTrue(EpisodeProgress.isNearEnd(positionSeconds: 1195, duration: 1200, thresholdSeconds: 30))
    }

    func testIsNearEndFalseForMissingDuration() {
        XCTAssertFalse(EpisodeProgress.isNearEnd(positionSeconds: 1195, duration: nil, thresholdSeconds: 30))
    }

    func testIsNearEndFalseForZeroDuration() {
        XCTAssertFalse(EpisodeProgress.isNearEnd(positionSeconds: 0, duration: 0, thresholdSeconds: 30))
    }

    func testIsNearEndFalseWhenThresholdDisabled() {
        XCTAssertFalse(EpisodeProgress.isNearEnd(positionSeconds: 1200, duration: 1200, thresholdSeconds: 0))
    }

    func testIsNearEndFalseForShortEpisodeNoLongerThanThreshold() {
        // A 30-second trailer with a 30-second threshold: the whole episode falls "within the
        // threshold" of its own end, so this must never fire just one second in (#704).
        XCTAssertFalse(EpisodeProgress.isNearEnd(positionSeconds: 1, duration: 30, thresholdSeconds: 30))
    }

    func testIsNearEndTrueForEpisodeLongerThanThresholdNearItsEnd() {
        XCTAssertTrue(EpisodeProgress.isNearEnd(positionSeconds: 25, duration: 40, thresholdSeconds: 30))
    }
}
