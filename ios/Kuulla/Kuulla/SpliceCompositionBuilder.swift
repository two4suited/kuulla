import AVFoundation

// A confirmed silent run in a downloaded episode's own source audio, in source-file seconds —
// the offline counterpart to SmartSpeedProcessor.SilenceRunDetector's real-time state machine.
// Codable so it round-trips through DownloadedEpisodeRecord.silenceMapData as JSON.
struct SilenceRange: Codable, Equatable {
    let start: TimeInterval
    let end: TimeInterval
}

// Builds the AVMutableComposition that plays a downloaded episode with its silence spliced out
// (#777), plus the time map every other feature needs to keep working against it.
//
// AVPlayer plays composition edits gaplessly and sample-accurately, so once a composition is
// built the pitch algorithm only ever runs at the user's chosen speed — no rate bursts, no
// rewind-on-resume. The same "excluded ranges" shape is what on-device ad skipping (#779) will
// feed this with later.
enum SpliceCompositionBuilder {
    // Seconds of a trimmed pause kept on each side of the cut (so ~half before, half after) —
    // removing a pause down to nothing reads as an edit; leaving this much lets speech keep its
    // natural rhythm. Matches the "splice pauses down to 0.25s" figure from the audio engine
    // research (docs/audio-engine-research.md, finding 5) that motivated this feature.
    static let defaultFloor: TimeInterval = 0.25

    enum SpliceError: Error {
        case compositionTrackCreationFailed
    }

    // One contiguous stretch of the source file to keep, in source seconds.
    struct KeptSegment: Equatable {
        let sourceStart: TimeInterval
        let sourceEnd: TimeInterval
    }

    // Pure: turns a set of confirmed silence runs into the ranges of source audio to actually
    // keep, cutting only the middle of each run wider than `floor` seconds and leaving `floor`
    // seconds of pause split across the seam. A run no wider than `floor` is left untouched
    // entirely — cutting it wouldn't save anything worth the extra edit. `excludedRanges` need
    // not be sorted; overlapping or out-of-order input is tolerated by processing in start order
    // and skipping any range that starts before the cursor already reached (i.e. inside a
    // previously-cut range).
    static func keptSegments(
        sourceDuration: TimeInterval, excludedRanges: [SilenceRange], floor: TimeInterval = defaultFloor
    ) -> [KeptSegment] {
        var segments: [KeptSegment] = []
        var cursor: TimeInterval = 0
        for range in excludedRanges.sorted(by: { $0.start < $1.start }) {
            guard range.end > range.start, range.start >= cursor else { continue }
            let cutStart = range.start + floor / 2
            let cutEnd = min(range.end - floor / 2, sourceDuration)
            guard cutEnd > cutStart else { continue }
            segments.append(KeptSegment(sourceStart: cursor, sourceEnd: cutStart))
            cursor = cutEnd
        }
        if cursor < sourceDuration {
            segments.append(KeptSegment(sourceStart: cursor, sourceEnd: sourceDuration))
        }
        return segments
    }

    // Builds the composition and its time map from an already-loaded asset/track pair — callers
    // are responsible for resolving those (synchronously for a local downloaded file, which is
    // fast enough not to need the async loadTracks pattern SmartSpeedProcessor's audio-mix setup
    // uses for the general, possibly-remote case).
    static func build(
        track: AVAssetTrack, sourceDuration: TimeInterval, excludedRanges: [SilenceRange], floor: TimeInterval = defaultFloor
    ) throws -> (composition: AVMutableComposition, timeMap: CompositionTimeMap) {
        let segments = keptSegments(sourceDuration: sourceDuration, excludedRanges: excludedRanges, floor: floor)
        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw SpliceError.compositionTrackCreationFailed }

        var mapSegments: [CompositionTimeMap.Segment] = []
        var cursor = CMTime.zero
        for segment in segments {
            let range = CMTimeRange(
                start: CMTime(seconds: segment.sourceStart, preferredTimescale: 600),
                end: CMTime(seconds: segment.sourceEnd, preferredTimescale: 600))
            guard range.duration > .zero else { continue }
            try compositionTrack.insertTimeRange(range, of: track, at: cursor)
            mapSegments.append(
                CompositionTimeMap.Segment(
                    sourceStart: segment.sourceStart, sourceEnd: segment.sourceEnd, compositionStart: cursor.seconds))
            cursor = cursor + range.duration
        }
        let totalTrimmed = max(0, sourceDuration - cursor.seconds)
        return (composition, CompositionTimeMap(segments: mapSegments, totalTrimmed: totalTrimmed))
    }
}

// Two-way mapping between an AVMutableComposition's own timeline (what AVPlayer's currentTime
// and seeks actually operate on) and the source file's timeline (what every other feature —
// chapters, outro-skip, transcript highlighting, progress sync — already assumes `currentTime`
// to be). AudioPlayer translates through this at its boundary so none of those consumers need to
// know a composition is involved at all.
struct CompositionTimeMap: Equatable {
    struct Segment: Equatable {
        let sourceStart: TimeInterval
        let sourceEnd: TimeInterval
        let compositionStart: TimeInterval
    }

    // Ascending by both sourceStart and compositionStart — SpliceCompositionBuilder.build
    // constructs them in source order, and composition time only ever increases with it.
    let segments: [Segment]
    // Total source seconds removed (i.e. the middles cut, not the floor kept around each seam) —
    // exactly what real-world listening time this composition saves versus playing the source
    // file unedited, before accounting for playback speed.
    let totalTrimmed: TimeInterval

    // Maps a position AVPlayer reports back to where it is in the original source file. Falls
    // back to the raw value when there are no segments (an empty/degenerate map) rather than
    // crashing — callers should treat that as "no composition in effect" beforehand, but this
    // keeps the function total.
    func sourceTime(fromComposition compositionTime: TimeInterval) -> TimeInterval {
        guard let segment = segments.last(where: { compositionTime >= $0.compositionStart }) ?? segments.first
        else { return compositionTime }
        return segment.sourceStart + (compositionTime - segment.compositionStart)
    }

    // Maps a source-file position (a saved resume position, a chapter start, an outro threshold)
    // to where AVPlayer should seek to play it. A source time that falls inside a spliced-out gap
    // (e.g. a chapter timestamp landing mid-cut) clamps to that segment's end — the nearest point
    // that's actually still in the composition — rather than landing in the following segment.
    func compositionTime(fromSource sourceTime: TimeInterval) -> TimeInterval {
        guard let segment = segments.last(where: { sourceTime >= $0.sourceStart }) ?? segments.first
        else { return sourceTime }
        let clamped = min(sourceTime, segment.sourceEnd)
        return segment.compositionStart + (clamped - segment.sourceStart)
    }
}
