import XCTest
@testable import Kuulla

final class TranscriptTests: XCTestCase {
    private func decode(_ json: String) throws -> TranscriptDocument {
        try JSONDecoder().decode(TranscriptDocument.self, from: Data(json.utf8))
    }

    func testDecodesSegmentsWithAndWithoutEndTime() throws {
        let document = try decode("""
        {
          "sourceType": "application/json",
          "segments": [
            { "startTime": "00:00:00", "endTime": "00:00:02.500", "text": "Hello there." },
            { "startTime": "00:00:02.500", "text": "General Kenobi." }
          ]
        }
        """)

        XCTAssertEqual(document.sourceType, "application/json")
        XCTAssertEqual(document.segments.count, 2)
        XCTAssertEqual(document.segments[0].startTime, 0)
        XCTAssertEqual(document.segments[0].endTime, 2.5)
        XCTAssertEqual(document.segments[0].text, "Hello there.")
        XCTAssertEqual(document.segments[1].startTime, 2.5)
        XCTAssertNil(document.segments[1].endTime)
    }

    func testDropsEndTimeThatPrecedesStart() throws {
        let document = try decode("""
        { "sourceType": null, "segments": [ { "startTime": "00:00:10", "endTime": "00:00:03", "text": "x" } ] }
        """)

        XCTAssertEqual(document.segments[0].startTime, 10)
        XCTAssertNil(document.segments[0].endTime)
    }

    func testFailsDecodeOnMalformedStartTime() {
        XCTAssertThrowsError(try decode("""
        { "sourceType": null, "segments": [ { "startTime": "not-a-timespan", "text": "x" } ] }
        """))
    }

    func testFailsDecodeOnNegativeStartTime() {
        XCTAssertThrowsError(try decode("""
        { "sourceType": null, "segments": [ { "startTime": "-00:00:05", "text": "x" } ] }
        """))
    }

    // MARK: - TranscriptSync.activeSegmentIndex

    private func segments(_ starts: [TimeInterval]) -> [TranscriptSegment] {
        starts.map { TranscriptSegment(startTime: $0, endTime: nil, text: "s\($0)") }
    }

    func testActiveSegmentIndexIsNilWhenEmpty() {
        XCTAssertNil(TranscriptSync.activeSegmentIndex(segments: [], currentTime: 5))
    }

    func testActiveSegmentIndexIsNilBeforeFirstSegment() {
        XCTAssertNil(TranscriptSync.activeSegmentIndex(segments: segments([10, 20]), currentTime: 5))
    }

    func testActiveSegmentIndexPicksGreatestStartAtOrBeforeNow() {
        let result = TranscriptSync.activeSegmentIndex(segments: segments([0, 10, 20, 30]), currentTime: 25)
        XCTAssertEqual(result, 2)
    }

    func testActiveSegmentIndexIncludesExactBoundary() {
        let result = TranscriptSync.activeSegmentIndex(segments: segments([0, 10, 20]), currentTime: 20)
        XCTAssertEqual(result, 2)
    }

    func testActiveSegmentIndexHandlesOutOfOrderSegments() {
        // Feed order isn't guaranteed sorted; the greatest reached start wins, not the last one.
        let result = TranscriptSync.activeSegmentIndex(segments: segments([30, 0, 10]), currentTime: 15)
        XCTAssertEqual(result, 2)
    }
}
