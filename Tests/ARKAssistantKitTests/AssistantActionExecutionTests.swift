/// Exercises the view model's action path and the pet state descriptor.

import Foundation
import Testing
@testable import ARKAssistantKit

@MainActor
final class StubActionExecutor: AssistantActionExecutor {
    var performed: [AssistantActionInvocation] = []
    var outcome = AssistantActionOutcome(message: "Studio session started for Demo Song.")

    func perform(_ invocation: AssistantActionInvocation) async -> AssistantActionOutcome {
        performed.append(invocation)
        return outcome
    }
}

@MainActor
struct AssistantActionExecutionTests {
    private static let catalog = AssistantActionCatalog(actions: [
        AssistantAction(
            name: "session.start",
            title: "Start Studio Session",
            description: "Starts a studio session.",
            category: .session,
            phrases: ["start session"]
        ),
    ])

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool, timeoutSeconds: Double = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    @Test func resolvedUtteranceCallsExecutorAndSetsVisual() async {
        let executor = StubActionExecutor()
        let model = AssistantChatViewModel(endpoint: nil, actionCatalog: Self.catalog, actionExecutor: executor)

        model.inputText = "Please start session"
        model.sendCurrentInput()

        let done = await waitUntil { model.messages.count == 2 && !model.isResponding }
        #expect(done)
        #expect(executor.performed.count == 1)
        #expect(executor.performed.first?.action.name == "session.start")
        #expect(executor.performed.first?.source == .text)
        #expect(model.messages.last?.role == .assistant)
        #expect(model.messages.last?.text == "Studio session started for Demo Song.")
        #expect(model.responseVisual?.component(id: "title")?.text == .literal("Start Studio Session"))
        #expect(model.lastActionInvocation?.action.name == "session.start")
        #expect(model.lastError == nil)
    }

    @Test func performActionWithoutExecutorReportsFailure() async {
        let model = AssistantChatViewModel(endpoint: nil, actionCatalog: Self.catalog)
        let invocation = AssistantActionInvocation(action: Self.catalog.actions[0], source: .pet)
        let outcome = await model.performAction(invocation)
        #expect(outcome.isFailure)
        #expect(model.messages.last?.text == outcome.message)
        #expect(model.responseVisual == nil)
    }

    @Test func failureOutcomeSurfacesError() async {
        let executor = StubActionExecutor()
        executor.outcome = .failure("No active project.")
        let model = AssistantChatViewModel(endpoint: nil, actionCatalog: Self.catalog, actionExecutor: executor)
        let outcome = await model.performAction(AssistantActionInvocation(action: Self.catalog.actions[0], source: .voice))
        #expect(outcome.isFailure)
        #expect(model.lastError == "No active project.")
        #expect(model.responseVisual?.component(id: "icon")?.name == .literal("exclamationmark.triangle.fill"))
    }

    @Test func muteRefusesPushToTalk() {
        let model = AssistantChatViewModel(endpoint: nil)
        #expect(!model.isMicrophoneMuted)
        model.toggleMicrophoneMuted()
        #expect(model.isMicrophoneMuted)
        model.startPushToTalk()
        #expect(!model.isRecording)
        #expect(model.voiceStatusText == "Microphone is muted")
        model.toggleMicrophoneMuted()
        #expect(!model.isMicrophoneMuted)
        #expect(model.voiceStatusText == nil)
    }

    @Test func voicePhaseDerivation() {
        #expect(AssistantVoicePhase.derive(isRecording: true, isResponding: true, isTranscribing: false, isSpeaking: true) == .listening)
        #expect(AssistantVoicePhase.derive(isRecording: false, isResponding: true, isTranscribing: false, isSpeaking: true) == .speaking)
        #expect(AssistantVoicePhase.derive(isRecording: false, isResponding: true, isTranscribing: false, isSpeaking: false) == .thinking)
        #expect(AssistantVoicePhase.derive(isRecording: false, isResponding: false, isTranscribing: true, isSpeaking: false) == .thinking)
        #expect(AssistantVoicePhase.derive(isRecording: false, isResponding: false, isTranscribing: false, isSpeaking: false) == .ready)
    }
}

struct ARKPetStateDescriptorTests {
    @Test func mapsPhasesToPresentation() {
        let ready = ARKPetStateDescriptor(phase: .ready, isMuted: false, error: nil)
        #expect(ready.symbol == "waveform" && ready.accent == .blue && ready.status == "Ready")
        #expect(!ready.pulses && !ready.showsCancel)

        let listening = ARKPetStateDescriptor(phase: .listening, isMuted: false, error: nil)
        #expect(listening.symbol == "mic.fill" && listening.accent == .red && listening.pulses)

        let thinking = ARKPetStateDescriptor(phase: .thinking, isMuted: false, error: nil)
        #expect(thinking.symbol == "sparkles" && thinking.accent == .purple && thinking.pulses)

        let speaking = ARKPetStateDescriptor(phase: .speaking, isMuted: false, error: nil)
        #expect(speaking.symbol == "speaker.wave.2.fill" && speaking.accent == .green && speaking.showsCancel)

        let unavailable = ARKPetStateDescriptor(phase: .unavailable, isMuted: false, error: nil)
        #expect(unavailable.accent == .orange && unavailable.status == "Unavailable" && !unavailable.pulses)
    }

    @Test func mutedAndErrorOverridesReady() {
        let muted = ARKPetStateDescriptor(phase: .ready, isMuted: true, error: nil)
        #expect(muted.symbol == "mic.slash" && muted.accent == .gray && muted.status == "Muted")

        let errored = ARKPetStateDescriptor(phase: .ready, isMuted: false, error: "Microphone access is required for push-to-talk.")
        #expect(errored.accent == .orange)
        #expect(errored.status.count <= 40)
        #expect(errored.status.hasSuffix("…"))

        // Listening while muted cannot happen, but the live phase still wins over the mute badge.
        let listeningMuted = ARKPetStateDescriptor(phase: .listening, isMuted: true, error: nil)
        #expect(listeningMuted.accent == .red)
    }
}
