import XCTest
@testable import Suggest

/// F19 (the owner 23.11): on a selection of several words the panel showed as a clipped square. It opened at 200 pt
/// before the selection was read; the top line then needed up to 460 pt and the window was not sized again until the
/// list came. The panel now sizes its window again after any layout whose content no longer matches it.
final class SuggestF19PanelTests: XCTestCase {

    /// The measured case: "Thinking…" with a 70-character original, in a window still at its opening size.
    func testAWiderContentThanTheWindowNeedsARefit() {
        XCTAssertTrue(SuggestCore.panelNeedsRefit(content: CGSize(width: 460, height: 58), window: CGSize(width: 200, height: 58)))
    }

    func testEveryDirectionCounts() {
        let window = CGSize(width: 320, height: 295)
        XCTAssertTrue(SuggestCore.panelNeedsRefit(content: CGSize(width: 330, height: 295), window: window))  // wider
        XCTAssertTrue(SuggestCore.panelNeedsRefit(content: CGSize(width: 310, height: 295), window: window))  // narrower
        XCTAssertTrue(SuggestCore.panelNeedsRefit(content: CGSize(width: 320, height: 330), window: window))  // taller
        XCTAssertTrue(SuggestCore.panelNeedsRefit(content: CGSize(width: 320, height: 58), window: window))   // shorter
    }

    func testAMatchingWindowNeedsNone() {
        XCTAssertFalse(SuggestCore.panelNeedsRefit(content: CGSize(width: 320, height: 295), window: CGSize(width: 320, height: 295)))
        XCTAssertFalse(SuggestCore.panelNeedsRefit(content: CGSize(width: 320.4, height: 294.6), window: CGSize(width: 320, height: 295)))
    }

    func testHalfAPointIsEnough() {
        XCTAssertTrue(SuggestCore.panelNeedsRefit(content: CGSize(width: 320.5, height: 295), window: CGSize(width: 320, height: 295)))
        XCTAssertTrue(SuggestCore.panelNeedsRefit(content: CGSize(width: 320, height: 295.5), window: CGSize(width: 320, height: 295)))
    }
}
