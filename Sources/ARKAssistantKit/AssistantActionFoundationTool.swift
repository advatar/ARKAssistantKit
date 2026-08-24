/// Binds the app action catalog as native FoundationModels tools, so Apple's
/// on-device model interprets intent and invokes actions in one pass instead
/// of round-tripping through a JSON-reply protocol.

import Foundation

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, macOS 26.0, *)
struct AssistantActionFoundationTool: FoundationModels.Tool {
    let name: String
    let description: String
    let parameters: GenerationSchema

    private let action: AssistantAction
    private let source: AssistantActionInvocation.Source
    private let perform: @Sendable @MainActor (AssistantActionInvocation) async -> AssistantActionOutcome

    typealias Arguments = GeneratedContent
    typealias Output = String

    init(
        action: AssistantAction,
        source: AssistantActionInvocation.Source,
        perform: @escaping @Sendable @MainActor (AssistantActionInvocation) async -> AssistantActionOutcome
    ) {
        self.action = action
        self.source = source
        self.perform = perform
        self.name = action.name
        var description = "\(action.title). \(action.description)"
        if action.requiresConfirmation {
            description += " Destructive: pass confirm=\"yes\" only when the user explicitly confirmed."
        }
        self.description = description

        var properties: [GenerationSchema.Property] = action.parameters.map { parameter in
            .init(
                name: parameter.name,
                description: parameter.title + (parameter.isRequired ? " (required)" : " (optional)"),
                type: String.self
            )
        }
        if action.requiresConfirmation {
            properties.append(.init(
                name: "confirm",
                description: "Pass \"yes\" only when the user explicitly confirmed this destructive action.",
                type: String.self
            ))
        }
        if properties.isEmpty {
            // GenerationSchema needs at least a stable shape; give argless
            // actions one ignorable optional field.
            properties = [.init(name: "note", description: "Unused; leave empty.", type: String.self)]
        }
        self.parameters = GenerationSchema(type: GeneratedContent.self, properties: properties)
    }

    func call(arguments: GeneratedContent) async throws -> String {
        var collected: [String: String] = [:]
        var names = action.parameters.map(\.name)
        if action.requiresConfirmation { names.append("confirm") }
        for name in names {
            if let value = try? arguments.value(String.self, forProperty: name),
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                collected[name] = value
            }
        }
        let invocation = AssistantActionInvocation(action: action, arguments: collected, source: source)
        let outcome = await perform(invocation)
        return outcome.isFailure ? "Not done: \(outcome.message)" : outcome.message
    }
}
#endif
