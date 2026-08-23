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

    @Test func longestPhraseWins() {
        let invocation = Self.catalog.resolve(utterance: "please end session now", source: .text)
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
        Sure, doing that now:
        ```json
        {"action": "session.start", "arguments": {"title": "Demo", "count": 2}}
        ```
        """
        let invocation = Self.catalog.invocation(fromModelReply: reply, source: .text)
        #expect(invocation?.action.name == "session.start")
        #expect(invocation?.arguments["title"] == "Demo")
        #expect(invocation?.arguments["count"] == "2")
    }

    @Test func parsesReplyByTitle() {
        let invocation = Self.catalog.invocation(fromModelReply: #"{"action":"End Studio Session"}"#, source: .voice)
        #expect(invocation?.action.name == "session.end")
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
