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
    runProcess(processor, samples: [Float](repeating: amplitude, count: sampleCount), itemTime: itemTime)
}

private func runProcess(
    _ processor: SmartSpeedProcessor, samples: [Float], itemTime: TimeInterval = 0
) -> (samples: [Float], silenceState: Bool?) {
    var samples = samples
    let sampleCount = samples.count
    var reported: Bool?
    processor.onSilenceStateChanged = { isSilent, _ in reported = isSilent }

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
        // Below the point where maxBoostGain would cap it: 0.2 / 0.1 = 2.
        let gain = SmartSpeedProcessor.boostGain(forLevel: 0.1)
        XCTAssertEqual(gain, SmartSpeedProcessor.boostTargetLevel / 0.1, accuracy: 0.001)
    }

    // Speech is peaky, so the RMS target routinely asks for more gain than the waveform has
    // headroom for — the applied gain is clamped to what keeps this buffer's peak under
    // peakCeiling instead of handing the excess to the limiter as distortion.
    func testPeakLimitedGainRespectsHeadroom() {
        XCTAssertEqual(SmartSpeedProcessor.peakLimitedGain(4, peak: 0.5), SmartSpeedProcessor.peakCeiling / 0.5, accuracy: 0.001)
        XCTAssertEqual(SmartSpeedProcessor.peakLimitedGain(1.5, peak: 0.5), 1.5)
        XCTAssertEqual(SmartSpeedProcessor.peakLimitedGain(4, peak: 0), 4)
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

    // MARK: softLimit(_:)

    func testSoftLimitIsIdentityBelowKnee() {
        XCTAssertEqual(SmartSpeedProcessor.softLimit(0.5), 0.5)
        XCTAssertEqual(SmartSpeedProcessor.softLimit(-0.3), -0.3)
        XCTAssertEqual(SmartSpeedProcessor.softLimit(SmartSpeedProcessor.limiterKnee), SmartSpeedProcessor.limiterKnee)
    }

    // No step in level or slope where the limiter engages — the transfer curve is continuous
    // through the knee, so the limiter engaging mid-buffer can't itself be heard as a click.
    func testSoftLimitIsContinuousAtKnee() {
        let knee = SmartSpeedProcessor.limiterKnee
        let justAbove = SmartSpeedProcessor.softLimit(knee + 0.001)
        XCTAssertEqual(justAbove, knee + 0.001, accuracy: 0.0001)
        XCTAssertGreaterThan(justAbove, knee)
    }

    // tanhf saturates to exactly 1 in Float for a large enough input, so full scale itself is
    // reachable — what matters is that nothing ever lands past it.
    func testSoftLimitNeverExceedsFullScale() {
        XCTAssertLessThanOrEqual(SmartSpeedProcessor.softLimit(10), 1)
        XCTAssertGreaterThan(SmartSpeedProcessor.softLimit(10), 0.99)
        XCTAssertGreaterThanOrEqual(SmartSpeedProcessor.softLimit(-10), -1)
        XCTAssertLessThan(SmartSpeedProcessor.softLimit(-10), -0.99)
        XCTAssertLessThan(SmartSpeedProcessor.softLimit(1.2), 1)
        XCTAssertGreaterThan(SmartSpeedProcessor.softLimit(-1.2), -1)
    }

    // MARK: silenceSkipRate(forPlaybackSpeed:)

    // The bare multiplier applies at ordinary speeds (4x on a 1x session) but the absolute skip
    // rate is capped, so a 3x session skips at 6x — not the 12x that turned the first second
    // after every pause into a chirp — and it can never come out below the session speed itself.
    func testSilenceSkipRateMultipliesAtLowSpeedsAndCapsAtHighSpeeds() {
        XCTAssertEqual(SmartSpeedProcessor.silenceSkipRate(forPlaybackSpeed: 1.0), 4.0)
        XCTAssertEqual(SmartSpeedProcessor.silenceSkipRate(forPlaybackSpeed: 1.5), 6.0)
        XCTAssertEqual(SmartSpeedProcessor.silenceSkipRate(forPlaybackSpeed: 2.0), SmartSpeedProcessor.maxSilenceSkipRate)
        XCTAssertEqual(SmartSpeedProcessor.silenceSkipRate(forPlaybackSpeed: 3.0), SmartSpeedProcessor.maxSilenceSkipRate)
        XCTAssertEqual(SmartSpeedProcessor.silenceSkipRate(forPlaybackSpeed: 8.0), 8.0)
    }

    // MARK: linearGain(forDb:) (#708)

    func testLinearGainIsExactlyOneAtZeroDb() {
        XCTAssertEqual(SmartSpeedProcessor.linearGain(forDb: 0), 1)
    }

    func testLinearGainDoublesRoughlyEverySixDb() {
        XCTAssertEqual(SmartSpeedProcessor.linearGain(forDb: 6), 1.995, accuracy: 0.01)
    }

    func testLinearGainHalvesRoughlyEveryNegativeSixDb() {
        XCTAssertEqual(SmartSpeedProcessor.linearGain(forDb: -6), 0.501, accuracy: 0.01)
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

// Coverage for the #679/#680 decoupling: SmartSpeedProcessor's silence-trim half and voice-boost
// half must each gate independently in process(), with the RMS level computation itself
// unconditional. The public init takes the three raw settings (smartSpeed, voiceBoost,
// trimSilence) — SmartSpeed has always trimmed silence and boosted quiet passages as both halves
// of its own effect (see the init's doc comment); that policy is enforced once inside the
// processor rather than at each call site.
final class SmartSpeedProcessorDecouplingTests: XCTestCase {
    // Voice Boost alone (SmartSpeed off) boosts gain but must never report a silence-state change,
    // even across many buffers of silence that would otherwise cross minimumSilenceDuration.
    func testVoiceBoostAloneBoostsButNeverReportsSilence() {
        let processor = SmartSpeedProcessor(smartSpeed: false, voiceBoost: true, trimSilence: false)
        processor.prepare()

        // A quiet-but-present level below boostTargetLevel should ramp gain upward over repeated
        // buffers (smoothedGain approaches boostGain(forLevel:) via gainReleaseFactor).
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
        let processor = SmartSpeedProcessor(smartSpeed: true, voiceBoost: false, trimSilence: false)
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

    // Trim Silence alone (SmartSpeed and Voice Boost both off) reports silence-state transitions
    // but must never boost gain — the counterpart voiceBoost's own tests never had (#680).
    func testTrimSilenceAloneReportsSilenceButDoesNotBoost() {
        let processor = SmartSpeedProcessor(smartSpeed: false, voiceBoost: false, trimSilence: true)
        processor.prepare()

        // A quiet-but-present level that would ramp gain upward if voice boost were enabled must
        // leave samples untouched here.
        for tick in 0..<20 {
            let (samples, silenceState) = runProcess(processor, amplitude: 0.05, itemTime: TimeInterval(tick) * 0.05)
            XCTAssertNil(silenceState, "no silent run yet")
            XCTAssertEqual(samples[0], 0.05, "voice boost is disabled; samples must pass through unchanged")
        }

        var sawSilenceStart = false
        for tick in 0..<20 {
            let (samples, silenceState) = runProcess(processor, amplitude: 0, itemTime: 20 + TimeInterval(tick) * 0.1)
            if silenceState == true { sawSilenceStart = true }
            XCTAssertEqual(samples[0], 0, "voice boost is disabled; silent samples must pass through unchanged")
        }
        XCTAssertTrue(sawSilenceStart, "silence transitions should still be reported with trimSilence alone")
    }
}

// Coverage for #708's fixed per-show/global volume offset — a static gain applied on top of (or
// entirely independent of) voiceBoost's dynamic boost.
final class SmartSpeedProcessorVolumeOffsetTests: XCTestCase {
    func testZeroOffsetLeavesSamplesUnchangedWithNoOtherEffectEnabled() {
        let processor = SmartSpeedProcessor(smartSpeed: false, voiceBoost: false, trimSilence: false, volumeOffsetDb: 0)
        processor.prepare()

        let (samples, _) = runProcess(processor, amplitude: 0.1)
        XCTAssertEqual(samples[0], 0.1)
    }

    func testPositiveOffsetBoostsSamplesWithNoVoiceBoostEnabled() {
        let processor = SmartSpeedProcessor(smartSpeed: false, voiceBoost: false, trimSilence: false, volumeOffsetDb: 6)
        processor.prepare()

        let (samples, _) = runProcess(processor, amplitude: 0.1)
        // 0.1 * ~2 lands well under the limiter's knee, so the boost is an exact linear multiply —
        // the previous unconditional tanh limiter would have shaved this to tanh(0.2) ≈ 0.197.
        let expectedGain = SmartSpeedProcessor.linearGain(forDb: 6)
        XCTAssertEqual(samples[0], 0.1 * expectedGain, accuracy: 0.0001)
        XCTAssertGreaterThan(samples[0], 0.1)
    }

    func testNegativeOffsetAttenuatesSamplesWithoutDistortion() {
        let processor = SmartSpeedProcessor(smartSpeed: false, voiceBoost: false, trimSilence: false, volumeOffsetDb: -6)
        processor.prepare()

        let (samples, _) = runProcess(processor, amplitude: 0.1)
        // Attenuation-only path skips the tanh limiter (see process()'s own rationale), so this
        // should be an exact linear multiply, not a soft-clipped value.
        let expectedGain = SmartSpeedProcessor.linearGain(forDb: -6)
        XCTAssertEqual(samples[0], 0.1 * expectedGain, accuracy: 0.0001)
        XCTAssertLessThan(samples[0], 0.1)
    }

    func testOffsetStillAppliesWhenVoiceBoostAlsoEnabled() {
        let processor = SmartSpeedProcessor(smartSpeed: false, voiceBoost: true, trimSilence: false, volumeOffsetDb: 6)
        processor.prepare()

        // Run several buffers so voiceBoost's smoothedGain has ramped toward its target — the
        // combined gain (dynamic boost * fixed offset) should exceed either alone.
        var lastSamples: [Float] = []
        for tick in 0..<20 {
            (lastSamples, _) = runProcess(processor, amplitude: 0.05, itemTime: TimeInterval(tick) * 0.05)
        }
        XCTAssertGreaterThan(lastSamples[0], SmartSpeedProcessor.boostGain(forLevel: 0.05) * 0.05 * 0.9)
    }
}

// The gain stage's behavior on program-level material — the audible half of Voice Boost that the
// pure-function tests above can't cover: ordinary speech must pass through untouched, and the
// smoothed gain must fall faster than it rises.
final class SmartSpeedProcessorGainStageTests: XCTestCase {
    // A buffer already at a normal speech level asks for a gain under 1, which the stage clamps
    // to a no-op — samples come out bit-identical, with no limiter involvement at all.
    func testNormalLevelSpeechPassesThroughUnchanged() {
        let processor = SmartSpeedProcessor(smartSpeed: false, voiceBoost: true, trimSilence: false)
        processor.prepare()

        for tick in 0..<10 {
            let (samples, _) = runProcess(processor, amplitude: 0.5, itemTime: TimeInterval(tick) * 0.05)
            XCTAssertEqual(samples[0], 0.5)
        }
    }

    // A loud buffer following a boosted quiet passage pulls the gain down by more in one buffer
    // (attack) than the very first quiet buffer pushed it up (release) — the asymmetry that keeps
    // a sudden louder passage from being shoved through the limiter for several buffers.
    func testGainAttacksFasterThanItReleases() {
        let processor = SmartSpeedProcessor(smartSpeed: false, voiceBoost: true, trimSilence: false)
        processor.prepare()

        let (firstQuiet, _) = runProcess(processor, amplitude: 0.05, itemTime: 0)
        let firstRise = firstQuiet[0] / 0.05 - 1
        XCTAssertGreaterThan(firstRise, 0)

        var rampedGain: Float = 1
        for tick in 1..<10 {
            let (samples, _) = runProcess(processor, amplitude: 0.05, itemTime: TimeInterval(tick) * 0.05)
            rampedGain = samples[0] / 0.05
        }
        XCTAssertGreaterThan(rampedGain, 2)

        // 0.3 is loud enough to demand gain < 1 but, after one attack step, still lands under the
        // limiter's knee — so the output is a plain multiply the gain can be read back from.
        let (loud, _) = runProcess(processor, amplitude: 0.3, itemTime: 0.5)
        let gainAfterLoud = loud[0] / 0.3
        XCTAssertLessThan(gainAfterLoud, rampedGain)
        XCTAssertGreaterThan(rampedGain - gainAfterLoud, firstRise)
    }

    // A single transient in an otherwise quiet buffer clamps only that buffer's gain — the
    // smoothed state is untouched, so the next quiet buffer is back at full boost instead of
    // ducked for the whole release time (the pumping a peak-driven attack would cause).
    func testTransientClampsOnlyItsOwnBuffer() {
        let processor = SmartSpeedProcessor(smartSpeed: false, voiceBoost: true, trimSilence: false)
        processor.prepare()

        var rampedGain: Float = 1
        for tick in 0..<20 {
            let (samples, _) = runProcess(processor, amplitude: 0.05, itemTime: TimeInterval(tick) * 0.05)
            rampedGain = samples[0] / 0.05
        }
        XCTAssertGreaterThan(rampedGain, 3)

        // A realistic-length buffer that's quiet apart from one 0.9 spike: the RMS barely moves
        // (target stays ~3.5x) but the peak forbids more than ~1.05x for this buffer.
        var spiky = [Float](repeating: 0.05, count: 1024)
        spiky[3] = 0.9
        let (clamped, _) = runProcess(processor, samples: spiky, itemTime: 1.0)
        XCTAssertLessThanOrEqual(clamped[3], SmartSpeedProcessor.peakCeiling + 0.0001)
        XCTAssertLessThan(clamped[0] / 0.05, 1.2)

        let (next, _) = runProcess(processor, amplitude: 0.05, itemTime: 1.05)
        XCTAssertGreaterThan(next[0] / 0.05, rampedGain * 0.95, "gain should not have been ducked by the transient")
    }

    // Gain holds steady through silent buffers instead of chasing a target computed from room
    // tone — no noise-floor swell during pauses, and the first word after one starts at the
    // gain the previous word ended on.
    func testGainHoldsThroughSilence() {
        let processor = SmartSpeedProcessor(smartSpeed: false, voiceBoost: true, trimSilence: false)
        processor.prepare()

        var rampedGain: Float = 1
        for tick in 0..<10 {
            let (samples, _) = runProcess(processor, amplitude: 0.05, itemTime: TimeInterval(tick) * 0.05)
            rampedGain = samples[0] / 0.05
        }
        // Room tone: below the silence threshold but above boostGain's near-silence guard.
        for tick in 0..<10 {
            let (samples, _) = runProcess(processor, amplitude: 0.002, itemTime: 1 + TimeInterval(tick) * 0.05)
            XCTAssertEqual(samples[0] / 0.002, rampedGain, accuracy: 0.001, "gain must hold, not swell, through silence")
        }
        let (resumed, _) = runProcess(processor, amplitude: 0.05, itemTime: 2)
        XCTAssertGreaterThanOrEqual(resumed[0] / 0.05, rampedGain)
    }

    // After a loud passage pulls the target under unity, the state floors at 1 — the next quiet
    // buffer starts boosting immediately rather than climbing out of a sub-unity dead zone.
    func testGainFloorsAtUnityAfterLoudPassage() {
        let processor = SmartSpeedProcessor(smartSpeed: false, voiceBoost: true, trimSilence: false)
        processor.prepare()

        for tick in 0..<10 {
            _ = runProcess(processor, amplitude: 0.5, itemTime: TimeInterval(tick) * 0.05)
        }
        let (firstQuiet, _) = runProcess(processor, amplitude: 0.05, itemTime: 1)
        XCTAssertGreaterThan(firstQuiet[0] / 0.05, 1.2, "boost should begin on the very first quiet buffer")
    }

    // Boosting a peaky buffer never pushes any sample past full scale, and the limiter leaves the
    // in-range samples of that same buffer alone.
    func testBoostedPeaksStayWithinFullScale() {
        let processor = SmartSpeedProcessor(smartSpeed: false, voiceBoost: false, trimSilence: false, volumeOffsetDb: 12)
        processor.prepare()

        let (samples, _) = runProcess(processor, samples: [0.1, 0.9, -0.9, 0.05])
        let gain = SmartSpeedProcessor.linearGain(forDb: 12)
        XCTAssertEqual(samples[0], 0.1 * gain, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(samples[1], 1)
        XCTAssertGreaterThanOrEqual(samples[2], -1)
        XCTAssertEqual(samples[3], 0.05 * gain, accuracy: 0.0001)
    }
}
