/// Exercises catalog phrase resolution and model-reply parsing.

import Testing
@testable import ARKAssistantKit

struct AssistantActionCatalogTests {
    static let catalog = AssistantActionCatalog(actions: [
        AssistantAction(
            name: "session.start",
            title: "Start Studio Session",
            description: "Starts a studio session.",
            category: .session,
            phrases: ["start session", "start a session", "begin recording"]
        ),
        AssistantAction(
            name: "session.end",
            title: "End Studio Session",
            description: "Ends the current session.",
            category: .session,
            phrases: ["end session", "stop the session"]
        ),
        AssistantAction(
            name: "protection.toggle",
            title: "Toggle Protection",
            description: "Toggles protection.",
            category: .protection,
            phrases: ["session"]
        ),
        AssistantAction(
            name: "evidence.note",
            title: "Log Note",
            description: "Logs a note to the session.",
            category: .evidence,
            phrases: ["log note {note}", "add a note {note}"],
            parameters: [AssistantActionParameter(name: "note", title: "Note", isRequired: true)]
        ),
    ])

    @Test func completePhraseDoesNotMatchShorterEmbeddedAction() {
        let invocation = Self.catalog.resolve(utterance: "please end session", source: .text)
        #expect(invocation?.action.name == "session.end")
    }

    @Test func normalizesPunctuationAndCase() {
        let invocation = Self.catalog.resolve(utterance: "Start   a Session!!", source: .voice)
        #expect(invocation?.action.name == "session.start")
        #expect(invocation?.source == .voice)
    }

    @Test func capturesPlaceholderRemainder() {
        let invocation = Self.catalog.resolve(utterance: "Log note: guitar take two was the keeper", source: .text)
        #expect(invocation?.action.name == "evidence.note")
        #expect(invocation?.arguments["note"] == "guitar take two was the keeper")
    }

    @Test func placeholderWithoutRemainderDoesNotMatch() {
        let invocation = Self.catalog.resolve(utterance: "log note", source: .text)
        #expect(invocation == nil)
    }

    @Test func noMatchReturnsNil() {
        #expect(Self.catalog.resolve(utterance: "what's the weather", source: .text) == nil)
        #expect(Self.catalog.resolve(utterance: "   ", source: .text) == nil)
    }

    @Test func parsesFencedModelReply() {
        let reply = """
        ```json
        {"action": "evidence.note", "arguments": {"note": "Guitar Take TWO"}}
        ```
        """
        let invocation = Self.catalog.invocation(fromModelReply: reply, source: .text)
        #expect(invocation?.action.name == "evidence.note")
        #expect(invocation?.arguments["note"] == "Guitar Take TWO")
    }

    @Test func requiresExactMachineActionName() {
        let invocation = Self.catalog.invocation(fromModelReply: #"{"action":"End Studio Session"}"#, source: .voice)
        #expect(invocation == nil)
    }

    @Test func negationQuotationsCompoundsAndParaphrasesAreNotSubstringCommands() {
        for text in ["don't start session", "do not start session", "never start session",
                     "please don't start session", "I said start session but changed my mind",
                     "what does start session do", "start session or end session",
                     "start session and end session", "\"start session\"", "“start session”",
                     "don't log note a guitar take", "could we begin making a fresh recording together",
                     "Before I go back to working on the bass line I would appreciate it if you could help me by showing the state of the current project"] {
            #expect(Self.catalog.resolve(utterance: text, source: .voice) == nil, "\(text)")
        }
    }

    @Test func duplicatePhraseAcrossActionsRequiresInterpretation() {
        let same = AssistantAction(name: "other", title: "Other", description: "Other", category: .assistant,
                                   phrases: ["start session"])
        let catalog = AssistantActionCatalog(actions: Self.catalog.actions + [same])
        #expect(catalog.resolve(utterance: "start session", source: .text) == nil)
    }

    @Test func malformedOrUntrustedModelDecisionsCannotExecute() {
        for reply in [#"{"action":"session.start","arguments":{"confirm":"yes"}}"#,
                      #"{"action":"evidence.note","arguments":{}}"#,
                      #"{"action":"evidence.note","arguments":{"note":true}}"#,
                      #"{"action":"session.start","arguments":null}"#,
                      #"{"action":"session.start","confirmed":true}"#,
                      #"{"action":"session.start"} {"action":"session.end"}"#,
                      #"Do not run {"action":"session.start"}"#] {
            #expect(Self.catalog.invocation(fromModelReply: reply, source: .text) == nil, "\(reply)")
        }
    }

    @Test func unknownActionOrProseReturnsNil() {
        #expect(Self.catalog.invocation(fromModelReply: #"{"action":"nope.none"}"#, source: .text) == nil)
        #expect(Self.catalog.invocation(fromModelReply: "Just chatting here.", source: .text) == nil)
        #expect(Self.catalog.invocation(fromModelReply: "{not json}", source: .text) == nil)
    }

    @Test func promptSummaryListsActionsAndArguments() {
        let summary = Self.catalog.promptSummary()
        #expect(summary.contains("- session.start: Starts a studio session."))
        #expect(summary.contains("- evidence.note: Logs a note to the session. (args: note)"))
    }
}

struct AssistantModelChoiceTests {
    @Test func choicesRoundTripAndHaveTitles() {
        for choice in AssistantModelChoice.allCases {
            #expect(AssistantModelChoice(rawValue: choice.rawValue) == choice)
            #expect(!choice.title.isEmpty)
        }
        #expect(AssistantModelChoice(rawValue: "nonsense") == nil)
    }
}
