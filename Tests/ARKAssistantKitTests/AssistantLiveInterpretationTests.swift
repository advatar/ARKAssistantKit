#if canImport(FoundationModels)
import Foundation
import FoundationModels
import Testing
@testable import ARKAssistantKit

/// Opt-in, serial, Apple-only text inference. Decisions remain in memory;
/// this never navigates the real app, starts audio, or modifies a project.
@MainActor
struct AssistantLiveInterpretationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ARK_ASSISTANT_LIVE_MODEL_TEST"] == "1"))
    func appleProviderRetainsConversationContextWithoutReplayingEarlierActions() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        #expect(SystemLanguageModel.default.isAvailable)
        guard SystemLanguageModel.default.isAvailable else { return }
        let response = try await AssistantLocalLLMClient().appleFoundationModelsResponse(
            prompt: """
                Host: ARK on iOS.
                Conversation history:
                User: I play the acoustic guitar.
                Assistant: We can capture your acoustic guitar contributions.
                User: Open Live Session.
                Assistant: The Live Session view was opened.
                """,
            instructions: "Answer the current user, using conversation context.",
            actionRequest: .init(utterance: "Which instrument did I say I play?", catalog: ARKAssistantActions.catalog))
        #expect(response.text.localizedCaseInsensitiveContains("guitar"))
        #expect(!response.permitsActionExecution)
        #expect(ARKAssistantActions.catalog.invocation(fromModelReply: response.text, source: .text) == nil)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ARK_ASSISTANT_LIVE_MODEL_TEST"] == "1"))
    func appleModelInterpretsParaphraseNegationAndAmbiguity() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        #expect(SystemLanguageModel.default.isAvailable, "Apple Intelligence must be available for this opt-in test")
        guard SystemLanguageModel.default.isAvailable else { return }
        let catalog = [
            AssistantAction(name: "navigation.evidence", title: "Show Proofs", description: "Opens the existing proofs view. Does not create or sign a proof.", category: .navigation, phrases: []),
            AssistantAction(name: "navigation.eventHistory", title: "Show History", description: "Opens the existing event history view.", category: .navigation, phrases: [])
        ]
        let cases: [(String, [String])] = [
            ("Before I leave for the day and head back to the studio with my collaborators could you please take me to the place where I can review all the proofs we already have", ["navigation.evidence"]),
            ("Don't show evidence. Leave the current view alone.", []),
            ("Open either the event history or the proofs. I haven't decided which I want yet.", []),
            ("I would like to look back over the events we recorded.", ["navigation.eventHistory"]),
            ("What would happen if I said show proofs?", [])
        ]
        for (phrase, expected) in cases {
            let actions = AssistantActionCatalog(actions: catalog)
            let reply = try await AssistantStructuredActionInterpreter.response(utterance: phrase, catalog: actions)
            let performed = reply.permitsActionExecution && !AssistantActionExecutionPolicy.requiresClarification(for: phrase)
                ? actions.invocation(fromModelReply: reply.text, source: .text).map { [$0.action.name] } ?? [] : []
            #expect(performed == expected, "\(phrase); decision: \(reply.text), executable: \(reply.permitsActionExecution)")
        }
    }
}
#endif
