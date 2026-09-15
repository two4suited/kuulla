import XCTest
@testable import Kuulla

final class SpliceCompositionBuilderTests: XCTestCase {
    // MARK: - keptSegments

    func testShortSilenceBelowFloorIsLeftUntouched() {
        // A 0.2s run is shorter than the default 0.25s floor — cutting it wouldn't leave the
        // floor's worth of pause on each side, so it's kept whole rather than edited.
        let segments = SpliceCompositionBuilder.keptSegments(
            sourceDuration: 10, excludedRanges: [SilenceRange(start: 4, end: 4.2)])
        XCTAssertEqual(segments, [.init(sourceStart: 0, sourceEnd: 10)])
    }

    func testLongSilenceIsCutLeavingFloorAroundTheSeam() {
        let floor: TimeInterval = 0.25
        let segments = SpliceCompositionBuilder.keptSegments(
            sourceDuration: 10, excludedRanges: [SilenceRange(start: 4, end: 6)], floor: floor)
        XCTAssertEqual(segments, [
            .init(sourceStart: 0, sourceEnd: 4 + floor / 2),
            .init(sourceStart: 6 - floor / 2, sourceEnd: 10),
        ])
    }

    func testMultipleSilencesProduceMultipleKeptSegments() {
        let segments = SpliceCompositionBuilder.keptSegments(
            sourceDuration: 20, excludedRanges: [
                SilenceRange(start: 5, end: 6), SilenceRange(start: 12, end: 13),
            ])
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments.first?.sourceStart, 0)
        XCTAssertEqual(segments.last?.sourceEnd, 20)
    }

    func testTrailingSilenceToTheEndOfFileStillKeepsTheFloorOnBothSidesOfTheCut() {
        // Even a silence run that reaches the very end of the file still keeps floor/2 before
        // and floor/2 after the cut — the trailing floor/2 here just happens to be the last
        // audio in the file, not a lead-in to more speech.
        let segments = SpliceCompositionBuilder.keptSegments(
            sourceDuration: 10, excludedRanges: [SilenceRange(start: 8, end: 10)])
        XCTAssertEqual(segments, [
            .init(sourceStart: 0, sourceEnd: 8.125),
            .init(sourceStart: 9.875, sourceEnd: 10),
        ])
    }

    func testUnsortedInputIsHandledInStartOrder() {
        let sorted = SpliceCompositionBuilder.keptSegments(
            sourceDuration: 20, excludedRanges: [SilenceRange(start: 12, end: 13), SilenceRange(start: 5, end: 6)])
        let reversed = SpliceCompositionBuilder.keptSegments(
            sourceDuration: 20, excludedRanges: [SilenceRange(start: 5, end: 6), SilenceRange(start: 12, end: 13)])
        XCTAssertEqual(sorted, reversed)
    }

    // MARK: - CompositionTimeMap

    private func makeTwoSegmentMap() -> CompositionTimeMap {
        // Source: [0, 4] kept, [4, 6] cut, [6, 10] kept -> composition: [0, 4] then [4, 8].
        CompositionTimeMap(
            segments: [
                .init(sourceStart: 0, sourceEnd: 4, compositionStart: 0),
                .init(sourceStart: 6, sourceEnd: 10, compositionStart: 4),
            ],
            totalTrimmed: 2)
    }

    func testSourceTimeRoundTripsWithinFirstSegment() {
        let map = makeTwoSegmentMap()
        XCTAssertEqual(map.sourceTime(fromComposition: 2), 2)
        XCTAssertEqual(map.compositionTime(fromSource: 2), 2)
    }

    func testSourceTimeRoundTripsWithinSecondSegment() {
        let map = makeTwoSegmentMap()
        // Composition time 5 is 1s into the second segment -> source time 6 + 1 = 7.
        XCTAssertEqual(map.sourceTime(fromComposition: 5), 7)
        XCTAssertEqual(map.compositionTime(fromSource: 7), 5)
    }

    func testSourceTimeInsideCutGapClampsToPrecedingSegmentEnd() {
        let map = makeTwoSegmentMap()
        // Source time 5 falls inside the cut [4, 6) — nearest still-composed point is the first
        // segment's end (composition time 4).
        XCTAssertEqual(map.compositionTime(fromSource: 5), 4)
    }

    func testCompositionTimeAtExactSegmentBoundaryPicksTheLaterSegment() {
        let map = makeTwoSegmentMap()
        XCTAssertEqual(map.sourceTime(fromComposition: 4), 6)
    }
}
