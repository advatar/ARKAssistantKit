import Testing
@testable import ARKAssistantKit

@MainActor
struct SessionAssistantTests {
    @Test func spokenRepliesRequireOptInAndQuietOverridesIt() {
        let model = AssistantChatViewModel(remoteToolsEnabled: false)
        #expect(!model.permitsSpokenReply)
        model.spokenRepliesEnabled = true
        #expect(model.permitsSpokenReply)
        model.setStudioQuiet(true)
        #expect(!model.permitsSpokenReply)
        #expect(!model.canUseVoice)
        model.startPushToTalk()
        #expect(!model.isRecording)
        model.inputText = "Can I still type?"
        #expect(model.canSend)
        model.setStudioQuiet(false)
        #expect(model.canUseVoice)
        #expect(model.permitsSpokenReply)
    }

    @Test func studioPersonaReachesModelAndDoesNotInventEvidence() async {
        let model = AssistantChatViewModel(remoteToolsEnabled: false)
        var received = false
        model.modelResponseOverride = { prompt, instructions in
            received = true
            #expect(prompt.contains(SessionAssistant.instructions))
            #expect(instructions.contains("cannot identify who performed a take"))
            #expect(instructions.contains("self-claimed identity"))
            #expect(instructions.contains("timing uncertainty"))
            return .init(text: "Let's check the recorded evidence together.", providerLabel: "Test", permitsActionExecution: false)
        }
        model.inputText = "How can you help us in the studio?"
        model.sendCurrentInput()
        await model.responseTask?.value
        #expect(received)
        #expect(!model.isRecording)
    }

    @Test func quietTransitionCancelsPendingResponseWithoutErasingConversation() async {
        let model = AssistantChatViewModel(remoteToolsEnabled: false)
        model.inputText = "Hello"
        model.sendCurrentInput()
        model.setStudioQuiet(true)
        #expect(model.responseTask == nil)
        #expect(!model.isResponding)
        #expect(model.messages.first?.text == "Hello")
        model.inputText = "Another question"
        #expect(model.canSend)
    }

    @Test func startingPointsUseExistingNonMutatingActions() {
        for name in ["navigation.liveSession", "navigation.eventHistory", "protection.projectStatus", "requests.pending", "navigation.evidence"] {
            #expect(ARKAssistantActions.catalog.action(named: name) != nil)
        }
    }
}
