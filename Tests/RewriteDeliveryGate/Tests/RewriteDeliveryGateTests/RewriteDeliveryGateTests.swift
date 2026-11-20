import XCTest
@testable import RewriteDeliveryGate

final class RewriteDeliveryGateTests: XCTestCase {
    private let selection = "The sky is blue."
    private let instruction = "make it a question"
    private let rewrite = "Is the sky blue?"

    func testFailedEnhancementDeliversNothing() {
        // Stock delivers the cleaned transcript, the spoken instruction, when enhancement fails or is skipped.
        let decision = RewriteDeliveryGate.decide(
            stockText: instruction, isRewrite: true, enhancedText: nil, selectedText: selection)
        XCTAssertNil(decision.text)
        XCTAssertEqual(decision.withheld, .noRewrite)
    }

    func testEmptyEnhancementResultDeliversNothing() {
        // A silent take: VoiceInk returns "" without a model call, and stock pastes "" over the selection.
        for blank in ["", " \n"] {
            let decision = RewriteDeliveryGate.decide(
                stockText: blank, isRewrite: true, enhancedText: blank, selectedText: selection)
            XCTAssertNil(decision.text, "result \(blank.debugDescription)")
            XCTAssertEqual(decision.withheld, .noRewrite, "result \(blank.debugDescription)")
        }
    }

    func testNoCapturedSelectionDeliversNothing() {
        for missing in [nil, "", " \n\t"] as [String?] {
            let decision = RewriteDeliveryGate.decide(
                stockText: rewrite, isRewrite: true, enhancedText: rewrite, selectedText: missing)
            XCTAssertNil(decision.text, "selection \(String(describing: missing))")
            XCTAssertEqual(decision.withheld, .noSelection, "selection \(String(describing: missing))")
        }
    }

    func testSuccessfulRewriteDeliversUnchanged() {
        let decision = RewriteDeliveryGate.decide(
            stockText: rewrite, isRewrite: true, enhancedText: rewrite, selectedText: selection)
        XCTAssertEqual(decision, .init(text: rewrite, withheld: nil))
    }

    func testOtherModesDeliverUnchanged() {
        let cases: [(stock: String?, enhanced: String?, selected: String?)] = [
            (instruction, nil, nil),          // enhancement failed or off, no selection
            (instruction, nil, selection),    // enhancement failed, selection present
            (rewrite, rewrite, nil),          // enhancement returned, no selection
            (rewrite, rewrite, selection),
            (nil, nil, nil),                  // nothing to deliver stays nothing
        ]
        for c in cases {
            let decision = RewriteDeliveryGate.decide(
                stockText: c.stock, isRewrite: false, enhancedText: c.enhanced, selectedText: c.selected)
            XCTAssertEqual(decision, .init(text: c.stock, withheld: nil), "\(c)")
        }
    }
}
