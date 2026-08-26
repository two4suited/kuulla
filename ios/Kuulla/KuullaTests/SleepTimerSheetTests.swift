import XCTest
@testable import Kuulla

final class SleepTimerSheetTests: XCTestCase {
    func testFormatRemainingReturnsNilWhenNoCountdownIsActive() {
        XCTAssertNil(SleepTimerSheet.formatRemaining(nil))
    }

    func testFormatRemainingFormatsWholeMinutesAndSeconds() {
        XCTAssertEqual(SleepTimerSheet.formatRemaining(905), "15:05")
    }

    func testFormatRemainingRoundsUpAFractionalSecond() {
        // A tick decrements by whole seconds, but rounding up (rather than truncating) avoids
        // ever briefly showing "0:00" while a fractional second of playback is still left.
        XCTAssertEqual(SleepTimerSheet.formatRemaining(0.4), "0:01")
    }

    func testFormatRemainingPadsSecondsUnderTen() {
        XCTAssertEqual(SleepTimerSheet.formatRemaining(63), "1:03")
    }
}
