import AVFoundation
import MediaToolbox

// Wraps an MTAudioProcessingTap installed on the current AVPlayerItem's audio track, implementing
// both halves of SmartSpeed (#202) without migrating off AVPlayer — see docs/smartspeed-spike.md
// for why this approach was chosen over an AVAudioEngine-based player.
//
// The gain-boost half also implements Voice Boost (#679) as an independently-toggleable behavior,
// and the silence-trim half likewise implements Trim Silence (#680) the same way: silenceTrimEnabled
// and voiceBoostEnabled gate the two halves separately, so either can run without the other
// (SmartSpeed alone still does both, exactly as before #679/#680; Voice Boost alone boosts without
// silence-trimming; Trim Silence alone trims without boosting; any combination does exactly its
// enabled halves without double-applying).
//
// The tap's process callback runs synchronously on a real-time audio thread, just before
// rendering, and only ever sees audio AVPlayer has already decoded/buffered.
//
// Silence trim is implemented as a temporary rate increase, not a seek: the tap only ever sees
// how long a silent run has been going so far, never how long it's about to continue, so there's
// no target position to seek to until the run has already ended — by which point that audio has
// already played. Speeding up while the run is confirmed ongoing, and dropping back to the
// configured rate the instant sound resumes, "trims" the pause perceptually without needing that
// lookahead.
//
// Assumes the tap's processingFormat is non-interleaved 32-bit float, which is what
// MTAudioProcessingTap negotiates for kMTAudioProcessingTapCreationFlag_PostEffects in practice;
// AudioPlayer only ever constructs this for its own AVPlayerItems, so there's no third-party
// asset whose native format could violate that assumption.
final class SmartSpeedProcessor {
    // Below this linear RMS level, a buffer counts as "silent" for trim purposes. ~-42 dBFS —
    // well below spoken-word level but above a typical codec noise floor, so genuine pauses
    // trigger without false-positiving on quiet-but-present speech.
    static let silenceThresholdLinear: Float = 0.008
    // Minimum contiguous silent run before it's worth speeding up through it — shorter gaps are
    // natural speech cadence (breaths, sentence pauses), not dead air.
    static let minimumSilenceDuration: TimeInterval = 0.8
    // The gain stage aims for this RMS level on each buffer (a soft ceiling, not a hard target)
    // and never applies more than maxBoostGain — bounds the boost so a quiet passage gets louder
    // without a stray loud sample in the same buffer clipping after being boosted.
    static let boostTargetLevel: Float = 0.35
    static let maxBoostGain: Float = 4.0
    // Fraction of the distance to the newly computed target gain closed per buffer, rather than
    // jumping straight to it — an instant gain change at a buffer boundary (tens of milliseconds)
    // is audible as pumping/zipper noise; ramping smooths the transition across buffers instead.
    static let gainSmoothingFactor: Float = 0.15
    // Multiplies the configured session rate while a silent run is confirmed ongoing.
    static let silenceSkipRateMultiplier: Float = 4.0

    // Invoked off the main thread from the tap's real-time callback exactly on each transition:
    // true the instant a silent run first crosses minimumSilenceDuration, false the instant sound
    // resumes after a confirmed run. Never fired redundantly for the same state.
    var onSilenceStateChanged: ((_ isSilent: Bool) -> Void)?

    // Invoked off the main thread from the tap's real-time callback whenever a confirmed silent
    // run ends (the same instant onSilenceStateChanged fires false), carrying that run's
    // itemTime duration — the raw input AudioPlayer needs to compute real-world time saved
    // (#680). Only fired while silenceTrimEnabled is true, same gating as onSilenceStateChanged.
    var onSilenceRunCompleted: ((_ runItemDuration: TimeInterval) -> Void)?

    // SmartSpeed has always trimmed silence and boosted quiet passages as both halves of its own
    // effect (the footer copy in SettingsView says as much) — that policy lives here, not at each
    // call site, so a future second construction site can't forget it and silently regress
    // SmartSpeed. Trim Silence (#680) and Voice Boost (#679) each let one half run standalone.
    private let silenceTrimEnabled: Bool
    private let voiceBoostEnabled: Bool
    // A fixed linear gain applied to every buffer regardless of voiceBoostEnabled — the per-show/
    // global VolumeOffsetDb setting (#708), a simpler, predictable complement to voiceBoostEnabled's
    // dynamic per-buffer boost. 1.0 (dB 0) is a true no-op: process() skips the multiply entirely
    // in that case, same as it always skipped voice-boost's gain stage when smoothedGain was ~1.
    private let volumeOffsetGain: Float

    private var silenceDetector = SilenceRunDetector()
    private var smoothedGain: Float = 1.0

    init(smartSpeed: Bool, voiceBoost: Bool, trimSilence: Bool, volumeOffsetDb: Float = 0) {
        self.silenceTrimEnabled = smartSpeed || trimSilence
        self.voiceBoostEnabled = smartSpeed || voiceBoost
        self.volumeOffsetGain = Self.linearGain(forDb: volumeOffsetDb)
    }

    // Builds an AVMutableAudioMix with this processor installed as the tap on `item`'s first
    // audio track. Returns an audio mix with no tap (a no-op passthrough) if the item has no
    // audio track or tap creation fails, rather than throwing — SmartSpeed degrading to "no
    // effect" is preferable to failing playback outright.
    //
    // async rather than blocking (#657): an earlier version dispatched loadTracks onto a
    // .userInteractive queue and blocked the calling thread on a semaphore, on the theory that
    // the queue's QoS would prevent a priority inversion. It didn't — AVFoundation's own
    // completion-handler thread for loadTracks doesn't reliably inherit the caller's QoS, so
    // Thread Performance Checker kept flagging the wait. Awaiting the async loadTracks overload
    // removes the blocking wait (and the inversion risk) entirely instead of trying to outrank it.
    func makeAudioMix(for item: AVPlayerItem) async -> AVMutableAudioMix {
        let mix = AVMutableAudioMix()
        guard let track = await Self.firstAudioTrack(of: item.asset) else { return mix }

        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            // Retained (not passUnretained) — this is the tap's ONLY strong reference to the
            // processor, released in the finalize callback below. The tap's own lifetime is owned
            // by `item`/`mix`, not by whatever AudioPlayer property happens to be holding this
            // SmartSpeedProcessor at any given moment — AudioPlayer.play() reassigns that property
            // synchronously on the main thread on every new play() call, while the previous tap's
            // real-time render thread can still have an in-flight or queued callback referencing
            // it. Tying the object's memory lifetime to the tap itself (rather than to that
            // property) avoids a use-after-free from that race.
            clientInfo: Unmanaged.passRetained(self).toOpaque(),
            init: smartSpeedTapInit,
            finalize: smartSpeedTapFinalize,
            prepare: smartSpeedTapPrepare,
            unprepare: smartSpeedTapUnprepare,
            process: smartSpeedTapProcess)

        // MTAudioProcessingTapCreate's `tapOut` C signature (CM_RETURNS_RETAINED_PARAMETER
        // MTAudioProcessingTapRef CM_NULLABLE * tapOut) imports into Swift differently across
        // toolchain versions: older Clang importers surface it as Unmanaged<MTAudioProcessingTap>?
        // (the caller must balance the +1 with takeRetainedValue()), newer ones recognize the
        // annotation and surface a directly ARC-managed MTAudioProcessingTap? instead. Branching
        // here keeps this buildable across both rather than pinning to whichever the current dev
        // toolchain happens to use.
        let tap: MTAudioProcessingTap?
        #if compiler(>=6.2)
        var directTap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &directTap)
        tap = directTap
        #else
        var unmanagedTap: Unmanaged<MTAudioProcessingTap>?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &unmanagedTap)
        tap = unmanagedTap?.takeRetainedValue()
        #endif
        guard status == noErr, let tap else {
            // Tap creation failed. Deliberately NOT attempting to release the passRetained(self)
            // above here: whether CoreMedia already balanced it internally (by invoking finalize
            // for a tap that got far enough to call init before some later step in Create failed)
            // is undocumented, and guessing wrong would double-release and crash. This failure
            // path is only reachable for a genuine tap-creation error (a real audio track was
            // already confirmed to exist above) — accepting a one-time leak of this processor in
            // that vanishingly rare case is a far safer trade-off than risking a crash.
            return mix
        }

        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        mix.inputParameters = [params]
        return mix
    }

    private static func firstAudioTrack(of asset: AVAsset) async -> AVAssetTrack? {
        (try? await asset.loadTracks(withMediaType: .audio))?.first
    }

    // Internal (not fileprivate) so tests can drive process() directly against a synthetic
    // AudioBufferList — mirrors SilenceRunDetector.observe's own test-seam visibility.
    func prepare() {
        silenceDetector = SilenceRunDetector()
        smoothedGain = 1.0
    }

    func process(bufferList: UnsafeMutableAudioBufferListPointer, itemTime: TimeInterval) {
        var sumOfSquares: Float = 0
        var sampleCount = 0
        for buffer in bufferList {
            guard let raw = buffer.mData else { continue }
            let samples = raw.assumingMemoryBound(to: Float.self)
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            for i in 0..<count {
                sumOfSquares += samples[i] * samples[i]
            }
            sampleCount += count
        }
        let level = sampleCount > 0 ? (sumOfSquares / Float(sampleCount)).squareRoot() : 0

        // Only ever boosts, never attenuates on its own — smoothedGain can ramp down below 1.0
        // (e.g. easing off a previous boost, or boostGain(forLevel:) itself dipping under 1 for an
        // already-loud passage), and pre-#708 that was always a no-op (the original gate was
        // `smoothedGain > 1.001`). Clamping here preserves that exact behavior for voiceBoost-only
        // sessions regardless of what volumeOffsetGain contributes below.
        var dynamicGain: Float = 1.0
        if voiceBoostEnabled {
            let targetGain = Self.boostGain(forLevel: level)
            smoothedGain += (targetGain - smoothedGain) * Self.gainSmoothingFactor
            dynamicGain = max(smoothedGain, 1.0)
        }

        let combinedGain = dynamicGain * volumeOffsetGain
        if abs(combinedGain - 1.0) > 0.001 {
            // A soft (tanh) limiter only when the combined gain could push samples outside ±1 —
            // an attenuation-only combinedGain (< 1, e.g. a negative volumeOffsetDb with no active
            // boost) can never clip, and tanh subtly distorts even well-inside-range samples, so a
            // plain multiply preserves quality for that common case.
            let needsLimiter = combinedGain > 1.0
            for buffer in bufferList {
                guard let raw = buffer.mData else { continue }
                let samples = raw.assumingMemoryBound(to: Float.self)
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                for i in 0..<count {
                    samples[i] = needsLimiter ? tanhf(samples[i] * combinedGain) : samples[i] * combinedGain
                }
            }
        }

        if silenceTrimEnabled, let isSilent = silenceDetector.observe(level: level, itemTime: itemTime) {
            onSilenceStateChanged?(isSilent)
            if !isSilent, let runDuration = silenceDetector.lastCompletedRunDuration {
                onSilenceRunCompleted?(runDuration)
            }
        }
    }

    // The gain the boost stage would apply to a buffer at this RMS level — pulled out as a pure
    // function so the boost math is unit-testable without a real AudioBufferList. A near-silent
    // level would otherwise compute a huge (and meaningless) gain from boostTargetLevel / level —
    // SilenceRunDetector handles that range instead of the boost stage, so gains of 1 (no-op) are
    // returned for it here.
    static func boostGain(forLevel level: Float) -> Float {
        guard level > 0.0001 else { return 1 }
        return min(maxBoostGain, boostTargetLevel / level)
    }

    // dB-to-linear-amplitude conversion for VolumeOffsetDb (#708). Exactly 0 dB returns exactly
    // 1.0 rather than pow(10, 0/20) (which is also 1.0, but this keeps the "no offset" case a
    // literal constant rather than relying on floating-point pow to land exactly on it).
    static func linearGain(forDb db: Float) -> Float {
        db == 0 ? 1 : pow(10, db / 20)
    }
}

// Tracks a contiguous run of silent buffers and reports state transitions only — pulled out as
// its own value type (mirroring AudioPlayer's shouldTriggerOutroSkip) so the state machine is
// unit-testable without a real tap.
struct SilenceRunDetector {
    private var candidateStartItemTime: TimeInterval?
    // itemTime at the instant a run is confirmed (crosses minimumSilenceDuration) — distinct from
    // candidateStartItemTime (when the run actually went quiet): the rate multiplier only applies
    // from confirmation onward, not for the leading minimumSilenceDuration stretch that still
    // played at the normal rate while the run was just a candidate. lastCompletedRunDuration must
    // measure from here, not from candidateStartItemTime, or every run's reported duration (and so
    // every #680 time-saved computation) overcounts by ~minimumSilenceDuration. Its own non-nil-ness
    // doubles as "is this run confirmed" — a separate isInConfirmedSilence Bool would just be
    // state that has to be kept in lockstep with this one instead of derived from it.
    private var confirmedStartItemTime: TimeInterval?

    // The just-ended confirmed run's sped-up itemTime duration (end itemTime minus
    // confirmedStartItemTime — the span that was actually played at the faster rate, not the
    // leading minimumSilenceDuration before confirmation) — set only on the same observe(...) call
    // that returns false, nil on every other call. A read-only side channel (#680) rather than
    // changing observe(...)'s own Bool? return shape, so every existing call site (and test)
    // keeping that shape doesn't need to change.
    private(set) var lastCompletedRunDuration: TimeInterval?

    // Returns true the instant a silent run first crosses SmartSpeedProcessor.minimumSilenceDuration,
    // false the instant a confirmed run ends (level rises back above threshold), and nil on every
    // other call (a run still below the duration threshold, a later buffer of an already-confirmed
    // run, or a non-silent buffer with no active run to end).
    mutating func observe(level: Float, itemTime: TimeInterval) -> Bool? {
        guard level < SmartSpeedProcessor.silenceThresholdLinear else {
            let confirmedStart = confirmedStartItemTime
            candidateStartItemTime = nil
            confirmedStartItemTime = nil
            guard let confirmedStart else {
                lastCompletedRunDuration = nil
                return nil
            }
            lastCompletedRunDuration = itemTime - confirmedStart
            return false
        }

        lastCompletedRunDuration = nil
        if candidateStartItemTime == nil {
            candidateStartItemTime = itemTime
        }

        guard confirmedStartItemTime == nil, let start = candidateStartItemTime,
              itemTime - start >= SmartSpeedProcessor.minimumSilenceDuration
        else { return nil }

        confirmedStartItemTime = itemTime
        return true
    }
}

private func smartSpeedTapInit(
    tap: MTAudioProcessingTap, clientInfo: UnsafeMutableRawPointer?,
    tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>
) {
    tapStorageOut.pointee = clientInfo
}

// Balances the passRetained(self) in makeAudioMix — this is what ties SmartSpeedProcessor's
// memory lifetime to the tap's own (owned by the AVPlayerItem/AVMutableAudioMix), independent of
// whatever AudioPlayer property references it.
private func smartSpeedTapFinalize(tap: MTAudioProcessingTap) {
    Unmanaged<SmartSpeedProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private func smartSpeedTapPrepare(
    tap: MTAudioProcessingTap, maxFrames: CMItemCount, processingFormat: UnsafePointer<AudioStreamBasicDescription>
) {
    Unmanaged<SmartSpeedProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().prepare()
}

private func smartSpeedTapUnprepare(tap: MTAudioProcessingTap) {}

private func smartSpeedTapProcess(
    tap: MTAudioProcessingTap, numberFrames: CMItemCount, flags: MTAudioProcessingTapFlags,
    bufferListInOut: UnsafeMutablePointer<AudioBufferList>, numberFramesOut: UnsafeMutablePointer<CMItemCount>,
    flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>
) {
    var itemTimeRange = CMTimeRange.invalid
    let status = MTAudioProcessingTapGetSourceAudio(
        tap, numberFrames, bufferListInOut, flagsOut, &itemTimeRange, numberFramesOut)
    guard status == noErr else { return }

    let processor = Unmanaged<SmartSpeedProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    let itemTime = itemTimeRange.start.isValid ? itemTimeRange.start.seconds : 0
    processor.process(bufferList: UnsafeMutableAudioBufferListPointer(bufferListInOut), itemTime: itemTime)
}
