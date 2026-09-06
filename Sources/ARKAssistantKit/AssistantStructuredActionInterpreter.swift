import Foundation
#if canImport(FoundationModels)
import FoundationModels

/// Apple guided generation proposes one decision. It never receives executable tools.
@available(iOS 26.0, macOS 26.0, *)
@MainActor
enum AssistantStructuredActionInterpreter {
    struct Decision {
        let text: String
        let permitsActionExecution: Bool
        var needsConversationalReply = false
    }

    static func response(utterance: String, catalog: AssistantActionCatalog) async throws -> Decision {
        let argumentNames = Array(Set(catalog.actions.flatMap { $0.parameters.map(\.name) })).sorted()
        let argumentSchema = DynamicGenerationSchema(name: "Arguments", properties: argumentNames.map {
            .init(name: $0, description: "User-specified \($0); omit if not explicitly supplied.",
                  schema: DynamicGenerationSchema(type: String.self), isOptional: true)
        })
        let schema = try GenerationSchema(root: DynamicGenerationSchema(name: "ActionDecision", properties: [
            .init(name: "userRequestSummary", description: "One sentence restating what the user actually wants, including any refusal, uncertainty, quoted wording, or change of mind. Do not describe merely the action words they mentioned.", schema: .init(type: String.self)),
            .init(name: "requestIsNegatedOrHypothetical", description: "True when the user is telling the app NOT to act, quoting an action, or asking hypothetically about it.", schema: .init(type: Bool.self)),
            .init(name: "requestNeedsClarification", description: "True when the user has not chosen between actions, requests several actions, or the intended target is ambiguous.", schema: .init(type: Bool.self)),
            .init(name: "action", description: "Exactly one requested action, or none for negation, uncertainty, hypothetical requests, unsupported operations or conversation.", schema: .init(name: "ActionName", anyOf: ["none"] + catalog.actions.map(\.name))),
            .init(name: "arguments", schema: argumentSchema),
            .init(name: "reply", description: "A short clarification or conversational reply if no action should run. Never claim an action has already been performed.", schema: .init(type: String.self))
        ]), dependencies: [])
        let instructions = """
            Classify the current user message into one app action or no action. Do not call tools or execute anything.
            Questions about what was said earlier are conversation, not requests to open a project.
            \(AssistantChatViewModel.actionInterpretationPolicy)
            Catalog:
            \(catalog.promptSummary())
            Examples:
            User: Don't open work. Decision: requestIsNegatedOrHypothetical=true, action=none.
            User: Open work or help, I am unsure which. Decision: requestNeedsClarification=true, action=none.
            User: What happens if I open work? Decision: requestIsNegatedOrHypothetical=true, action=none.
            User: I would like to see my pending invitations. Decision: select the pending-requests action if present.
            User: Open work. Actually, open help instead. Decision: select only help if present.
            """
        let session = LanguageModelSession(instructions: instructions)
        let result = try await session.respond(to: Prompt(utterance), schema: schema,
            options: GenerationOptions(temperature: 0, maximumResponseTokens: 600))
        try Task.checkCancellation()
        let decision = result.content
        let negated = try decision.value(Bool.self, forProperty: "requestIsNegatedOrHypothetical")
        let ambiguous = try decision.value(Bool.self, forProperty: "requestNeedsClarification")
        let name = try decision.value(String.self, forProperty: "action")
        guard !negated, !ambiguous, name != "none" else {
            return Decision(text: try decision.value(String.self, forProperty: "reply"),
                            permitsActionExecution: false, needsConversationalReply: !negated && !ambiguous)
        }
        let rawArguments = try decision.value(GeneratedContent.self, forProperty: "arguments")
        var arguments: [String: String] = [:]
        for key in argumentNames {
            if let value = try? rawArguments.value(String.self, forProperty: key),
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { arguments[key] = value }
        }
        let data = try JSONSerialization.data(withJSONObject: ["action": name, "arguments": arguments], options: [.sortedKeys])
        return Decision(text: String(decoding: data, as: UTF8.self), permitsActionExecution: true)
    }
}
#endif
