import XCTest
@testable import Kuulla

final class SmartSpeedProcessorTests: XCTestCase {
    func testBoostGainIsNoopForNearSilentPeak() {
        XCTAssertEqual(SmartSpeedProcessor.boostGain(forPeak: 0.00005), 1)
    }

    func testBoostGainLiftsQuietPeakTowardTarget() {
        // Below the point where maxBoostGain would cap it: 0.85 / 0.3 ≈ 2.833.
        let gain = SmartSpeedProcessor.boostGain(forPeak: 0.3)
        XCTAssertEqual(gain, 0.85 / 0.3, accuracy: 0.001)
    }

    func testBoostGainNeverExceedsMaximum() {
        // A quiet-enough peak would otherwise compute a gain far past maxBoostGain.
        let gain = SmartSpeedProcessor.boostGain(forPeak: 0.01)
        XCTAssertEqual(gain, SmartSpeedProcessor.maxBoostGain)
    }

    func testBoostGainIsAttenuatingForAlreadyLoudPeak() {
        // Already louder than the target peak, so the "gain" comes back under 1 — the caller
        // (SmartSpeedProcessor.process) treats anything <= 1 as a no-op rather than attenuating.
        XCTAssertLessThan(SmartSpeedProcessor.boostGain(forPeak: 0.9), 1)
    }
}

final class SilenceRunDetectorTests: XCTestCase {
    func testDoesNotReportBeforeMinimumDurationElapses() {
        var detector = SilenceRunDetector()
        XCTAssertNil(detector.observe(peak: 0, itemTime: 0))
        XCTAssertNil(detector.observe(peak: 0, itemTime: 0.3))
    }

    func testReportsExactlyOnceWhenRunCrossesMinimumDuration() {
        var detector = SilenceRunDetector()
        _ = detector.observe(peak: 0, itemTime: 10.0)
        XCTAssertNil(detector.observe(peak: 0, itemTime: 10.5))

        let report = detector.observe(peak: 0, itemTime: 10.9)
        XCTAssertEqual(report?.start, 10.0)
        XCTAssertEqual(report?.duration ?? 0, 0.9, accuracy: 0.001)

        // Same run continuing past the threshold must not report again.
        XCTAssertNil(detector.observe(peak: 0, itemTime: 11.5))
    }

    func testNonSilentPeakResetsTheRun() {
        var detector = SilenceRunDetector()
        _ = detector.observe(peak: 0, itemTime: 0)
        XCTAssertNil(detector.observe(peak: 0.5, itemTime: 0.5))

        // A fresh silent run afterward starts its own timer rather than resuming the old one.
        XCTAssertNil(detector.observe(peak: 0, itemTime: 0.6))
        XCTAssertNil(detector.observe(peak: 0, itemTime: 1.0))

        let report = detector.observe(peak: 0, itemTime: 1.5)
        XCTAssertEqual(report?.start, 0.6)
    }

    func testPeakAtThresholdIsNotSilent() {
        var detector = SilenceRunDetector()
        XCTAssertNil(detector.observe(peak: SmartSpeedProcessor.silenceThresholdLinear, itemTime: 0))
        XCTAssertNil(detector.observe(peak: SmartSpeedProcessor.silenceThresholdLinear, itemTime: 5))
    }
}
