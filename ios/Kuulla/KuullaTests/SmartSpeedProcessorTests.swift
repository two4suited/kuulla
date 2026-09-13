import AVFoundation
import XCTest
@testable import Kuulla

// Builds a single-buffer, non-interleaved-float AudioBufferList populated with `sampleCount`
// samples all at `amplitude`, runs it through the processor, and reports back the resulting
// (possibly gain-adjusted) samples plus whatever onSilenceStateChanged reported (if anything) —
// so tests can assert on both halves of process() without hand-rolling raw buffer plumbing each
// time.
private func runProcess(
    _ processor: SmartSpeedProcessor, amplitude: Float, sampleCount: Int = 8, itemTime: TimeInterval = 0
) -> (samples: [Float], silenceState: Bool?) {
    var samples = [Float](repeating: amplitude, count: sampleCount)
    var reported: Bool?
    processor.onSilenceStateChanged = { reported = $0 }

    let result: [Float] = samples.withUnsafeMutableBufferPointer { pointer -> [Float] in
        let audioBuffer = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(sampleCount * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(pointer.baseAddress))
        var bufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: audioBuffer)
        withUnsafeMutablePointer(to: &bufferList) { listPointer in
            processor.process(
                bufferList: UnsafeMutableAudioBufferListPointer(listPointer), itemTime: itemTime)
        }
        return Array(pointer)
    }
    return (result, reported)
}

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

// Coverage for the #679 decoupling: SmartSpeedProcessor's silence-trim half and voice-boost half
// must each gate independently in process(), with the RMS level computation itself unconditional.
// The public init only takes the two raw settings (smartSpeed, voiceBoost) — it deliberately
// doesn't expose "silence trim without boost" as a constructible state, since SmartSpeed has
// always boosted quiet passages as half of its own effect (see the init's doc comment); that
// policy is enforced once inside the processor rather than at each call site.
final class SmartSpeedProcessorDecouplingTests: XCTestCase {
    // Voice Boost alone (SmartSpeed off) boosts gain but must never report a silence-state change,
    // even across many buffers of silence that would otherwise cross minimumSilenceDuration.
    func testVoiceBoostAloneBoostsButNeverReportsSilence() {
        let processor = SmartSpeedProcessor(smartSpeed: false, voiceBoost: true)
        processor.prepare()

        // A quiet-but-present level below boostTargetLevel should ramp gain upward over repeated
        // buffers (smoothedGain approaches boostGain(forLevel:) via gainSmoothingFactor).
        var lastSamples: [Float] = []
        for tick in 0..<20 {
            let (samples, silenceState) = runProcess(processor, amplitude: 0.05, itemTime: TimeInterval(tick) * 0.9)
            XCTAssertNil(silenceState, "voiceBoost-only must never report a silence transition")
            lastSamples = samples
        }
        XCTAssertGreaterThan(lastSamples[0], 0.05, "quiet samples should have been boosted upward")

        // Feed enough contiguous silence to cross minimumSilenceDuration — still must not report.
        for tick in 0..<20 {
            let (_, silenceState) = runProcess(processor, amplitude: 0, itemTime: 20 + TimeInterval(tick) * 0.1)
            XCTAssertNil(silenceState, "silence trim is disabled; no transition should ever be reported")
        }
    }

    // SmartSpeed on (voiceBoost off at the call site) still boosts quiet passages and reports
    // silence transitions — SmartSpeed's own boost policy is preserved bit-for-bit.
    func testBothEnabledDoesBothWithoutDoubleApplying() {
        let processor = SmartSpeedProcessor(smartSpeed: true, voiceBoost: false)
        processor.prepare()

        var lastSamples: [Float] = []
        for tick in 0..<20 {
            (lastSamples, _) = runProcess(processor, amplitude: 0.05, itemTime: TimeInterval(tick) * 0.05)
        }
        XCTAssertGreaterThan(lastSamples[0], 0.05, "quiet samples should still be boosted when both are on")

        var sawSilenceStart = false
        for tick in 0..<20 {
            let (_, silenceState) = runProcess(processor, amplitude: 0, itemTime: 20 + TimeInterval(tick) * 0.1)
            if silenceState == true { sawSilenceStart = true }
        }
        XCTAssertTrue(sawSilenceStart, "silence transitions should still be reported when both are on")
    }
}
