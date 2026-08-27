import Foundation

// The transcript endpoint's response: timed segments normalized from whatever source format the
// feed published (JSON Podcast Transcript, SRT, or VTT), plus the MIME type they came from.
struct TranscriptDocument: Decodable {
    let sourceType: String?
    let segments: [TranscriptSegment]
}

// One timed line of a transcript. startTime/endTime arrive as the same .NET TimeSpan string
// format as Episode.duration, decoded through the shared parseDuration helper. endTime is
// optional because word-level sources only carry a start time per token.
struct TranscriptSegment: Decodable, Equatable {
    let startTime: TimeInterval
    let endTime: TimeInterval?
    let text: String

    private enum CodingKeys: String, CodingKey {
        case startTime, endTime, text
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let startTimeText = try container.decode(String.self, forKey: .startTime)
        // Fails the decode rather than defaulting to 0 — a segment silently placed at 0:00 for a
        // malformed timestamp would steal the active-segment highlight and misdirect a tap-to-seek.
        // A negative value is rejected too; a transcript line can't precede the start of the episode.
        guard let parsedStart = Episode.parseDuration(startTimeText), parsedStart >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .startTime, in: container, debugDescription: "Invalid TimeSpan value: \(startTimeText)")
        }
        startTime = parsedStart

        if let endTimeText = try container.decodeIfPresent(String.self, forKey: .endTime),
           let parsedEnd = Episode.parseDuration(endTimeText), parsedEnd >= parsedStart {
            endTime = parsedEnd
        } else {
            // A missing, malformed, or before-the-start endTime just drops to nil — the segment
            // is still usable with only a start time rather than failing the whole document.
            endTime = nil
        }

        text = try container.decode(String.self, forKey: .text)
    }

    // Non-decoding initializer for tests and previews.
    init(startTime: TimeInterval, endTime: TimeInterval?, text: String) {
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }
}

enum TranscriptSync {
    // The index of the segment currently being spoken: the greatest startTime <= currentTime.
    // Found by comparison rather than `.last`, mirroring ChapterScrubber.activeChapterIndex —
    // the API preserves the feed's own ordering, which isn't guaranteed to be sorted by time.
    static func activeSegmentIndex(segments: [TranscriptSegment], currentTime: TimeInterval) -> Int? {
        segments.indices
            .filter { segments[$0].startTime <= currentTime }
            .max { segments[$0].startTime < segments[$1].startTime }
    }
}
