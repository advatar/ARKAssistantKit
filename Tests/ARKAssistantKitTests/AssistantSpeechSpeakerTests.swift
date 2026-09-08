import Testing
@testable import ARKAssistantKit

@MainActor
struct AssistantSpeechSpeakerTests {
    @Test func idleCleanupNeverInitializesTheSystemSpeechEngine() {
        let speaker = AssistantSpeechSpeaker()
        var changes: [Bool] = []
        speaker.onSpeakingChange = { changes.append($0) }
        for _ in 0..<100 { speaker.stop() }
        #expect(speaker.synthesizer == nil)
        #expect(!speaker.isSpeaking)
        #expect(changes.isEmpty)
    }

    @Test func emptySpeechDoesNotInitializeTheSystemSpeechEngine() async {
        let speaker = AssistantSpeechSpeaker()
        await speaker.speak("  \n ")
        #expect(speaker.synthesizer == nil)
        #expect(!speaker.isSpeaking)
    }
}
