import Foundation
import Testing
@testable import ARKAssistantKit

@MainActor
private final class SuspendedPetAction: AssistantActionExecutor {
    let started = AsyncStream<Void>.makeStream()
    var continuation: CheckedContinuation<AssistantActionOutcome, Never>?

    func perform(_ invocation: AssistantActionInvocation) async -> AssistantActionOutcome {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.continuation.yield(())
            started.continuation.finish()
        }
    }
}

@MainActor
struct AssistantInteractionCancellationTests {
    private let action = AssistantAction(name: "status", title: "Status", description: "Test status",
                                         category: .assistant, phrases: ["status"])

    @Test func hidingCancelsLateActionResultWithoutRepopulatingConversation() async {
        let executor = SuspendedPetAction()
        let model = AssistantChatViewModel(endpoint: URL(string: "http://127.0.0.1:1/mcp"),
            actionCatalog: AssistantActionCatalog(actions: [action]), actionExecutor: executor)
        model.inputText = "status"
        model.sendCurrentInput()
        let task = model.responseTask
        for await _ in executor.started.stream { break }
        #expect(model.isResponding)

        model.cancelInteraction(clearConversation: true)
        #expect(!model.isResponding)
        #expect(model.messages.isEmpty)
        executor.continuation?.resume(returning: AssistantActionOutcome(message: "Old account's result"))
        await task?.value

        #expect(model.messages.isEmpty)
        #expect(model.responseVisual == nil)
        #expect(model.lastActionInvocation == nil)
        #expect(model.lastError == nil)
    }

    @Test func immediateCloseCancelsQueuedSubmissionBeforeItStarts() async {
        let executor = SuspendedPetAction()
        let model = AssistantChatViewModel(endpoint: URL(string: "http://127.0.0.1:1/mcp"),
            actionCatalog: AssistantActionCatalog(actions: [action]), actionExecutor: executor)
        model.inputText = "status"
        model.sendCurrentInput()
        let task = model.responseTask
        model.cancelInteraction(clearConversation: true)
        await task?.value
        #expect(executor.continuation == nil)
        #expect(model.messages.isEmpty)
        #expect(!model.isResponding)
    }

    @Test func closeKeepsMutePreferenceAndDoesNotStartCapture() {
        let model = AssistantChatViewModel(endpoint: URL(string: "http://127.0.0.1:1/mcp"))
        model.toggleMicrophoneMuted()
        model.cancelInteraction()
        model.cancelInteraction(clearConversation: true)
        #expect(model.isMicrophoneMuted)
        #expect(!model.isRecording)
        #expect(!model.isSpeaking)
        #expect(!model.isTranscribingVoice)
    }

    @Test func localConversationDoesNotRequireRemoteToolDiscovery() {
        #expect(!AssistantChatViewModel.requiresRemoteDiscovery(
            hasLocalActions: true, hasCachedTools: false, requestedInventory: false))
        #expect(!AssistantChatViewModel.requiresRemoteDiscovery(
            hasLocalActions: false, hasCachedTools: true, requestedInventory: false))
        #expect(AssistantChatViewModel.requiresRemoteDiscovery(
            hasLocalActions: false, hasCachedTools: false, requestedInventory: false))
        #expect(AssistantChatViewModel.requiresRemoteDiscovery(
            hasLocalActions: true, hasCachedTools: true, requestedInventory: true))
    }

    @Test func cancelledModelRequestDoesNotStartProviderOrFallback() async {
        let client = AssistantLocalLLMClient()
        let request = Task { @MainActor in
            try await client.response(prompt: "Do not submit this", instructions: "Test only")
        }
        request.cancel()
        do {
            _ = try await request.value
            Issue.record("A cancelled request must not produce a response")
        } catch is CancellationError {
            // Cancellation is preserved instead of trying another provider.
        } catch {
            Issue.record("Expected cancellation, got \(error)")
        }
    }
}
