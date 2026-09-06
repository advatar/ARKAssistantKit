import Foundation
import Testing
@testable import ARKAssistantKit

@MainActor
struct AssistantNaturalLanguageRoutingTests {
    private let action = AssistantAction(name: "navigation.evidence", title: "Show Evidence",
        description: "Opens existing proofs, without creating or signing anything.", category: .navigation,
        phrases: ["show evidence"])

    @Test func fullParaphraseReachesModelAndItsValidatedDecisionReachesExecutor() async {
        for phrase in ["Where can I see the evidence we collected?",
                       "Before I leave for the day and head back to the studio with my collaborators could you please take me to the place where I can review all the proofs we already have"] {
            let executor = StubActionExecutor()
            let model = AssistantChatViewModel(endpoint: URL(string: "http://127.0.0.1:1/mcp"),
                actionCatalog: .init(actions: [action]), actionExecutor: executor)
            var modelWasCalled = false
            model.modelResponseOverride = { prompt, instructions in
                modelWasCalled = true
                #expect(prompt.contains(phrase))
                #expect(instructions.contains(AssistantChatViewModel.actionInterpretationPolicy))
                return .init(text: #"{"action":"navigation.evidence","arguments":{}}"#, providerLabel: "test stub")
            }
            model.inputText = phrase
            model.sendCurrentInput()
            await model.responseTask?.value
            #expect(modelWasCalled)
            #expect(executor.performed.map(\.action.name) == [action.name])
        }
    }

    @Test func negationAndAmbiguityReachInterpreterWithoutFastPathExecution() async {
        for phrase in ["don't show evidence", "show evidence or leave this view open",
                       "what does show evidence mean", "\"show evidence\""] {
            let executor = StubActionExecutor()
            let model = AssistantChatViewModel(endpoint: URL(string: "http://127.0.0.1:1/mcp"),
                actionCatalog: .init(actions: [action]), actionExecutor: executor)
            var seen = false
            model.modelResponseOverride = { prompt, _ in
                seen = prompt.contains(phrase)
                return .init(text: "I haven't opened anything. What would you like to do?", providerLabel: "test stub")
            }
            model.inputText = phrase
            model.sendCurrentInput()
            await model.responseTask?.value
            #expect(seen)
            #expect(executor.performed.isEmpty)
        }
    }

    @Test func nonExecutableDecisionCannotSmuggleActionJSONInConversationalReply() async {
        let executor = StubActionExecutor()
        let model = AssistantChatViewModel(endpoint: URL(string: "http://127.0.0.1:1/mcp"),
            actionCatalog: .init(actions: [action]), actionExecutor: executor)
        model.modelResponseOverride = { _, _ in
            .init(text: #"{"action":"navigation.evidence","arguments":{}}"#,
                  providerLabel: "test stub", permitsActionExecution: false)
        }
        model.inputText = "don't show evidence"
        model.sendCurrentInput()
        await model.responseTask?.value
        #expect(executor.performed.isEmpty)
    }

    @Test func mistakenModelCannotExecuteExplicitNegationHypotheticalOrAlternatives() async {
        for phrase in ["don't show evidence", "What would happen if I said show proofs?",
                       "Open proofs or history", "Please don't fail to show evidence", "Open proofs for \"Song\""] {
            let executor = StubActionExecutor()
            let model = AssistantChatViewModel(endpoint: URL(string: "http://127.0.0.1:1/mcp"),
                actionCatalog: .init(actions: [action]), actionExecutor: executor)
            var reachedModel = false
            model.modelResponseOverride = { _, _ in
                reachedModel = true
                return .init(text: #"{"action":"navigation.evidence","arguments":{}}"#, providerLabel: "mistaken test model")
            }
            model.inputText = phrase
            model.sendCurrentInput()
            await model.responseTask?.value
            #expect(reachedModel)
            #expect(executor.performed.isEmpty)
            #expect(model.messages.last?.text.contains("please ask directly") == true)
        }
    }
}
