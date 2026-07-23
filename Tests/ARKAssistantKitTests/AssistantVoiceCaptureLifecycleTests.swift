import XCTest
@testable import ARKAssistantKit

final class AssistantVoiceCaptureLifecycleTests: XCTestCase {
    func testReleaseInvalidatesPendingStartup() {
        var gate = AssistantVoiceCaptureGate()
        let token = gate.request()

        XCTAssertTrue(gate.permits(token))
        gate.cancel()

        XCTAssertFalse(gate.isRequested)
        XCTAssertFalse(gate.permits(token))
    }

    func testOldStartupCannotWinAfterSecondPress() {
        var gate = AssistantVoiceCaptureGate()
        let first = gate.request()
        gate.cancel()
        let second = gate.request()

        XCTAssertFalse(gate.permits(first))
        XCTAssertTrue(gate.permits(second))
        gate.finish(first)
        XCTAssertTrue(gate.permits(second))
    }

    @MainActor
    func testFinalTranscriptWinsOverPartial() {
        XCTAssertEqual(
            AssistantChatViewModel.resolvedVoiceTranscript(
                final: "  final words  ",
                partial: "partial words"
            ),
            "final words"
        )
    }

    @MainActor
    func testPartialTranscriptIsFallback() {
        XCTAssertEqual(
            AssistantChatViewModel.resolvedVoiceTranscript(
                final: "   ",
                partial: "  partial words  "
            ),
            "partial words"
        )
    }
}
