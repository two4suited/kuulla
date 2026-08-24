import AVFoundation
import MediaToolbox

// Wraps an MTAudioProcessingTap installed on the current AVPlayerItem's audio track, implementing
// both halves of SmartSpeed (#202) without migrating off AVPlayer — see docs/smartspeed-spike.md
// for why this approach was chosen over an AVAudioEngine-based player.
//
// The tap's process callback runs synchronously on a real-time audio thread, just before
// rendering, and only ever sees audio AVPlayer has already decoded/buffered — so a skip triggered
// from a detected silent run never seeks into not-yet-buffered network audio.
//
// Assumes the tap's processingFormat is non-interleaved 32-bit float, which is what
// MTAudioProcessingTap negotiates for kMTAudioProcessingTapCreationFlag_PostEffects in practice;
// AudioPlayer only ever constructs this for its own AVPlayerItems, so there's no third-party
// asset whose native format could violate that assumption.
final class SmartSpeedProcessor {
    // Below this linear amplitude, a frame counts as "silent" for trim purposes. ~-42 dBFS —
    // well below spoken-word level but above a typical codec noise floor, so genuine pauses
    // trigger without false-positiving on quiet-but-present speech.
    static let silenceThresholdLinear: Float = 0.008
    // Minimum contiguous silent run before it's worth interrupting playback to skip — shorter
    // gaps are natural speech cadence (breaths, sentence pauses), not dead air.
    static let minimumSilenceDuration: TimeInterval = 0.8
    // The gain stage aims for this peak on each buffer (a soft ceiling, not a hard target) and
    // never applies more than this multiplier — bounds the boost so a quiet passage gets louder
    // without a stray loud sample in the same buffer clipping after being boosted.
    static let boostTargetPeak: Float = 0.85
    static let maxBoostGain: Float = 4.0

    // Invoked off the main thread from the tap's real-time callback whenever a silent run first
    // crosses minimumSilenceDuration. itemTime/runDuration describe the run so far — AudioPlayer
    // re-derives "now" from its own currentTime when it actually seeks, since both values are
    // already stale by the time the dispatch to main lands.
    var onSilenceDetected: ((_ itemTime: TimeInterval, _ runDuration: TimeInterval) -> Void)?

    private var silenceDetector = SilenceRunDetector()

    // Builds an AVMutableAudioMix with this processor installed as the tap on `item`'s first
    // audio track. Returns an audio mix with no tap (a no-op passthrough) if the item has no
    // audio track or tap creation fails, rather than throwing — SmartSpeed degrading to "no
    // effect" is preferable to failing playback outright.
    func makeAudioMix(for item: AVPlayerItem) -> AVMutableAudioMix {
        let mix = AVMutableAudioMix()
        guard let track = item.asset.tracks(withMediaType: .audio).first else { return mix }

        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passUnretained(self).toOpaque(),
            init: smartSpeedTapInit,
            finalize: smartSpeedTapFinalize,
            prepare: smartSpeedTapPrepare,
            unprepare: smartSpeedTapUnprepare,
            process: smartSpeedTapProcess)

        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let tap else { return mix }

        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        mix.inputParameters = [params]
        return mix
    }

    fileprivate func prepare() {
        silenceDetector = SilenceRunDetector()
    }

    fileprivate func process(bufferList: UnsafeMutableAudioBufferListPointer, itemTime: TimeInterval) {
        var peak: Float = 0
        for buffer in bufferList {
            guard let raw = buffer.mData else { continue }
            let samples = raw.assumingMemoryBound(to: Float.self)
            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            for i in 0..<sampleCount {
                peak = max(peak, abs(samples[i]))
            }
        }

        let gain = Self.boostGain(forPeak: peak)
        if gain > 1 {
            for buffer in bufferList {
                guard let raw = buffer.mData else { continue }
                let samples = raw.assumingMemoryBound(to: Float.self)
                let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                for i in 0..<sampleCount {
                    samples[i] = max(-1, min(1, samples[i] * gain))
                }
            }
        }

        if let (start, duration) = silenceDetector.observe(peak: peak, itemTime: itemTime) {
            onSilenceDetected?(start, duration)
        }
    }

    // The gain the boost stage would apply to a buffer with this peak amplitude — pulled out as
    // a pure function so the boost math is unit-testable without a real AudioBufferList.
    // A near-silent peak would otherwise compute a huge (and meaningless) gain from
    // boostTargetPeak / peak — SilenceRunDetector handles that range instead of the boost stage,
    // so gains of 1 (no-op) are returned for it here.
    static func boostGain(forPeak peak: Float) -> Float {
        guard peak > 0.0001 else { return 1 }
        return min(maxBoostGain, boostTargetPeak / peak)
    }
}

// Tracks a contiguous run of silent buffers and reports it exactly once, as soon as it crosses
// minimumSilenceDuration — pulled out as its own value type (mirroring AudioPlayer's
// shouldTriggerOutroSkip) so the run/report state machine is unit-testable without a real tap.
struct SilenceRunDetector {
    private var startItemTime: TimeInterval?
    private var hasReportedCurrentRun = false

    // Returns (runStartItemTime, runDurationSoFar) the first time a silent run crosses
    // SmartSpeedProcessor.minimumSilenceDuration, and nil on every other call (including every
    // later buffer of the same already-reported run, and every non-silent buffer).
    mutating func observe(peak: Float, itemTime: TimeInterval) -> (start: TimeInterval, duration: TimeInterval)? {
        guard peak < SmartSpeedProcessor.silenceThresholdLinear else {
            startItemTime = nil
            hasReportedCurrentRun = false
            return nil
        }

        if startItemTime == nil {
            startItemTime = itemTime
            hasReportedCurrentRun = false
        }

        guard !hasReportedCurrentRun, let start = startItemTime else { return nil }
        let duration = itemTime - start
        guard duration >= SmartSpeedProcessor.minimumSilenceDuration else { return nil }

        hasReportedCurrentRun = true
        return (start, duration)
    }
}

private func smartSpeedTapInit(
    tap: MTAudioProcessingTap, clientInfo: UnsafeMutableRawPointer?,
    tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>
) {
    tapStorageOut.pointee = clientInfo
}

private func smartSpeedTapFinalize(tap: MTAudioProcessingTap) {}

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
