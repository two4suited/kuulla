import XCTest
@testable import Kuulla

final class SmartSpeedProcessorTests: XCTestCase {
    func testBoostGainIsNoopForNearSilentLevel() {
        XCTAssertEqual(SmartSpeedProcessor.boostGain(forLevel: 0.00005), 1)
    }

    func testBoostGainLiftsQuietLevelTowardTarget() {
        // Below the point where maxBoostGain would cap it: 0.35 / 0.2 = 1.75.
        let gain = SmartSpeedProcessor.boostGain(forLevel: 0.2)
        XCTAssertEqual(gain, 0.35 / 0.2, accuracy: 0.001)
    }

    func testBoostGainNeverExceedsMaximum() {
        // A quiet-enough level would otherwise compute a gain far past maxBoostGain.
        let gain = SmartSpeedProcessor.boostGain(forLevel: 0.01)
        XCTAssertEqual(gain, SmartSpeedProcessor.maxBoostGain)
    }

    func testBoostGainIsAttenuatingForAlreadyLoudLevel() {
        // Already louder than the target level, so the "gain" comes back under 1 — the caller
        // (SmartSpeedProcessor.process) treats anything <= 1 as a no-op rather than attenuating.
        XCTAssertLessThan(SmartSpeedProcessor.boostGain(forLevel: 0.9), 1)
    }
}

final class SilenceRunDetectorTests: XCTestCase {
    func testDoesNotReportBeforeMinimumDurationElapses() {
        var detector = SilenceRunDetector()
        XCTAssertNil(detector.observe(level: 0, itemTime: 0))
        XCTAssertNil(detector.observe(level: 0, itemTime: 0.3))
    }

    func testReportsSilenceStartExactlyOnceWhenRunCrossesMinimumDuration() {
        var detector = SilenceRunDetector()
        _ = detector.observe(level: 0, itemTime: 10.0)
        XCTAssertNil(detector.observe(level: 0, itemTime: 10.5))

        XCTAssertEqual(detector.observe(level: 0, itemTime: 10.9), true)

        // Same run continuing past the threshold must not report again.
        XCTAssertNil(detector.observe(level: 0, itemTime: 11.5))
    }

    func testReportsSilenceEndOnceAfterAConfirmedRun() {
        var detector = SilenceRunDetector()
        _ = detector.observe(level: 0, itemTime: 0)
        XCTAssertEqual(detector.observe(level: 0, itemTime: 0.9), true)

        XCTAssertEqual(detector.observe(level: 0.5, itemTime: 1.0), false)

        // Already-ended state must not report "ended" again on a later non-silent buffer.
        XCTAssertNil(detector.observe(level: 0.5, itemTime: 1.5))
    }

    func testNonSilentLevelBeforeConfirmationResetsTheRunWithoutReporting() {
        var detector = SilenceRunDetector()
        _ = detector.observe(level: 0, itemTime: 0)
        // Ends before crossing minimumSilenceDuration — never confirmed, so no "ended" report.
        XCTAssertNil(detector.observe(level: 0.5, itemTime: 0.5))

        // A fresh silent run afterward starts its own timer rather than resuming the old one.
        XCTAssertNil(detector.observe(level: 0, itemTime: 0.6))
        XCTAssertNil(detector.observe(level: 0, itemTime: 1.0))
        XCTAssertEqual(detector.observe(level: 0, itemTime: 1.5), true)
    }

    func testLevelAtThresholdIsNotSilent() {
        var detector = SilenceRunDetector()
        XCTAssertNil(detector.observe(level: SmartSpeedProcessor.silenceThresholdLinear, itemTime: 0))
        XCTAssertNil(detector.observe(level: SmartSpeedProcessor.silenceThresholdLinear, itemTime: 5))
    }
}
