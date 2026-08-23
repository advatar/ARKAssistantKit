/// Defines the app-action contract shared by the ARK assistant, the ARK pet, and Siri App Intents.
///
/// Every user-facing action that the app can perform is described once as an `AssistantAction`
/// in an `AssistantActionCatalog`. The host app implements `AssistantActionExecutor` to perform
/// them. The same catalog drives: voice/text intent resolution in the assistant, Siri/Shortcuts
/// App Intents, and the pet's spoken confirmations and A2UI visuals.

import Foundation

/// A single parameter an action accepts. Values are always passed as strings (or omitted).
public struct AssistantActionParameter: Sendable, Equatable, Codable {
    public let name: String
    public let title: String
    public let isRequired: Bool

    public init(name: String, title: String, isRequired: Bool = false) {
        self.name = name
        self.title = title
        self.isRequired = isRequired
    }
}

/// A user-facing capability of the app that can be invoked by voice, text, or Siri.
public struct AssistantAction: Sendable, Equatable, Identifiable, Codable {
    public enum Category: String, Sendable, Codable, CaseIterable {
        case navigation
        case protection
        case session
        case signing
        case requests
        case evidence
        case account
        case assistant
    }

    /// Stable, machine-readable identifier (e.g. `"session.start"`).
    public let name: String
    /// Short human title used in menus, Siri and confirmations (e.g. `"Start Studio Session"`).
    public let title: String
    /// One-sentence description of what happens.
    public let description: String
    public let category: Category
    /// Trigger phrases. Matching is case-insensitive; `{note}`-style placeholders capture free text
    /// into the named parameter. Phrases without placeholders match when the utterance contains them.
    public let phrases: [String]
    public let parameters: [AssistantActionParameter]
    /// When `true`, the executor should require an explicit confirmation before a destructive step.
    public let requiresConfirmation: Bool

    public var id: String { name }

    public init(
        name: String,
        title: String,
        description: String,
        category: Category,
        phrases: [String],
        parameters: [AssistantActionParameter] = [],
        requiresConfirmation: Bool = false
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.category = category
        self.phrases = phrases
        self.parameters = parameters
        self.requiresConfirmation = requiresConfirmation
    }
}

/// A resolved request to run an action with concrete parameters.
public struct AssistantActionInvocation: Sendable, Equatable {
    public let action: AssistantAction
    public var arguments: [String: String]
    /// Where the invocation came from; executors may use it for audit metadata.
    public let source: Source

    public enum Source: String, Sendable {
        case voice
        case text
        case siri
        case pet
        case shortcutURL
    }

    public init(action: AssistantAction, arguments: [String: String] = [:], source: Source) {
        self.action = action
        self.arguments = arguments
        self.source = source
    }
}

/// What the executor reports back after performing an action.
public struct AssistantActionOutcome: Sendable, Equatable {
    /// Short message suitable for speech and chat (e.g. "Studio session started for Demo Song.").
    public let message: String
    /// Optional A2UI surface (JSON, `application/a2ui+json`) the pet/assistant may render.
    public let a2uiSurfaceJSON: String?
    /// `true` when the action was *not* performed and the message explains why.
    public let isFailure: Bool

    public init(message: String, a2uiSurfaceJSON: String? = nil, isFailure: Bool = false) {
        self.message = message
        self.a2uiSurfaceJSON = a2uiSurfaceJSON
        self.isFailure = isFailure
    }

    public static func failure(_ message: String) -> AssistantActionOutcome {
        AssistantActionOutcome(message: message, isFailure: true)
    }
}

/// Implemented by the host app. Must be safe to call from the main actor.
@MainActor
public protocol AssistantActionExecutor: AnyObject {
    func perform(_ invocation: AssistantActionInvocation) async -> AssistantActionOutcome
}

/// The full set of actions an app exposes, with deterministic utterance resolution.
public struct AssistantActionCatalog: Sendable, Equatable {
    public let actions: [AssistantAction]

    public init(actions: [AssistantAction]) {
        self.actions = actions
    }

    public func action(named name: String) -> AssistantAction? {
        let needle = Self.normalize(name)
        return actions.first { Self.normalize($0.name) == needle }
            ?? actions.first { Self.normalize($0.title) == needle }
    }

    /// Resolves a natural-language utterance to an action using the catalog's phrases.
    /// Longer phrase matches win so "end session" beats "session". Returns `nil` when no phrase matches.
    public func resolve(utterance: String, source: AssistantActionInvocation.Source) -> AssistantActionInvocation? {
        let normalized = Self.normalize(utterance)
        guard !normalized.isEmpty else { return nil }

        var best: (action: AssistantAction, arguments: [String: String], score: Int)?
        for action in actions {
            for phrase in action.phrases {
                guard let match = Self.match(phrase: phrase, in: normalized) else { continue }
                if best == nil || match.score > best!.score {
                    best = (action, match.arguments, match.score)
                }
            }
        }
        guard let best else { return nil }
        return AssistantActionInvocation(action: best.action, arguments: best.arguments, source: source)
    }

    /// Compact textual description of the catalog for LLM prompts.
    public func promptSummary(limit: Int = 60) -> String {
        actions.prefix(limit).map { action in
            let params = action.parameters.isEmpty
                ? ""
                : " (args: \(action.parameters.map(\.name).joined(separator: ", ")))"
            return "- \(action.name): \(action.description)\(params)"
        }.joined(separator: "\n")
    }

    /// Parses an LLM reply of the form `{"action":"name","arguments":{...}}` (optionally wrapped in
    /// prose or a code fence) into an invocation. Unknown action names resolve to `nil`.
    public func invocation(fromModelReply reply: String, source: AssistantActionInvocation.Source) -> AssistantActionInvocation? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end else { return nil }
        let json = String(reply[start...end])
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["action"] as? String,
              let action = action(named: name) else {
            return nil
        }
        var arguments: [String: String] = [:]
        if let raw = object["arguments"] as? [String: Any] {
            for (key, value) in raw {
                if let string = value as? String { arguments[key] = string }
                else if let number = value as? NSNumber { arguments[key] = number.stringValue }
            }
        }
        return AssistantActionInvocation(action: action, arguments: arguments, source: source)
    }

    // MARK: - Matching

    nonisolated static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let scalars = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == " " || scalar == "{" || scalar == "}" {
                return Character(scalar)
            }
            return " "
        }
        return String(scalars)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    private struct PhraseMatch {
        let score: Int
        let arguments: [String: String]
    }

    private static func match(phrase: String, in normalizedUtterance: String) -> PhraseMatch? {
        let normalizedPhrase = normalize(phrase)
        guard !normalizedPhrase.isEmpty else { return nil }

        // Placeholder form: "log note {note}" → literal prefix + captured remainder.
        if let open = normalizedPhrase.firstIndex(of: "{"),
           let close = normalizedPhrase.firstIndex(of: "}"),
           open < close {
            let parameter = String(normalizedPhrase[normalizedPhrase.index(after: open)..<close])
            let literal = normalizedPhrase[..<open].trimmingCharacters(in: .whitespaces)
            guard !literal.isEmpty,
                  let range = normalizedUtterance.range(of: literal) else { return nil }
            let remainder = normalizedUtterance[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !remainder.isEmpty else { return nil }
            return PhraseMatch(score: literal.count + 1, arguments: [parameter: remainder])
        }

        let padded = " \(normalizedUtterance) "
        guard padded.contains(" \(normalizedPhrase) ") else { return nil }
        return PhraseMatch(score: normalizedPhrase.count, arguments: [:])
    }
}
