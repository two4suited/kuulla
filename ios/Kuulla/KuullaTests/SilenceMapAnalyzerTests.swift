import XCTest
@testable import Kuulla

final class SilenceMapAnalyzerTests: XCTestCase {
    private let loud: Float = 0.5
    private let quiet: Float = 0.0001

    // Synthesizes a sequence of (itemTime, level) readings from a list of (duration, level)
    // segments, mirroring how the real analyzer would see a stream of decoded chunks. itemTime is
    // computed as index * step rather than by repeatedly adding step, so accumulated
    // floating-point drift across many samples can't shift a crossing by a whole step.
    private func levels(segments: [(duration: TimeInterval, level: Float)], step: TimeInterval = 0.1) -> [(itemTime: TimeInterval, level: Float)] {
        var result: [(TimeInterval, Float)] = []
        var index = 0
        for segment in segments {
            let count = Int((segment.duration / step).rounded())
            for _ in 0..<count {
                result.append((TimeInterval(index) * step, segment.level))
                index += 1
            }
        }
        return result
    }

    func testNoSilenceProducesNoRanges() {
        let readings = levels(segments: [(duration: 2, level: loud)])
        XCTAssertEqual(SilenceMapAnalyzer.silenceRanges(levels: readings), [])
    }

    func testSilenceShorterThanMinimumDurationProducesNoRange() {
        // 0.5s of silence never crosses the 0.8s confirmation window.
        let readings = levels(segments: [(duration: 1, level: loud), (duration: 0.5, level: quiet), (duration: 1, level: loud)])
        XCTAssertEqual(SilenceMapAnalyzer.silenceRanges(levels: readings), [])
    }

    func testConfirmedSilenceProducesOneRange() {
        let readings = levels(segments: [(duration: 1, level: loud), (duration: 2, level: quiet), (duration: 1, level: loud)])
        let ranges = SilenceMapAnalyzer.silenceRanges(levels: readings)
        XCTAssertEqual(ranges.count, 1)
        guard let range = ranges.first else { return }
        // Confirmed at 1 + minimumSilenceDuration; the range's reported start backs off by that
        // same window so it covers the whole run, not just the post-confirmation tail.
        XCTAssertEqual(range.start, 1, accuracy: 0.05)
        XCTAssertEqual(range.end, 3, accuracy: 0.15)
    }

    func testTwoSeparateSilencesProduceTwoRanges() {
        let readings = levels(segments: [
            (duration: 1, level: loud), (duration: 1.5, level: quiet), (duration: 1, level: loud),
            (duration: 1.2, level: quiet), (duration: 1, level: loud),
        ])
        XCTAssertEqual(SilenceMapAnalyzer.silenceRanges(levels: readings).count, 2)
    }

    func testTrailingSilenceWithNoFollowingSoundProducesNoRange() {
        // observe() only reports false (and so only appends a range) once sound resumes — a file
        // that ends mid-silence never gets that transition, mirroring the real-time tap's own
        // behavior for an episode that fades to silence at the very end.
        let readings = levels(segments: [(duration: 1, level: loud), (duration: 2, level: quiet)])
        XCTAssertEqual(SilenceMapAnalyzer.silenceRanges(levels: readings), [])
    }
}
