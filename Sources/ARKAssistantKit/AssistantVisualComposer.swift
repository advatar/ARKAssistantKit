/// Deterministically composes small A2UI surfaces from assistant action outcomes and replies.
///
/// The composer never calls a model. It inspects plain text for bullet lines, numbered steps and
/// `Key: value` rows and emits a card with a title, an icon and at most `maxLines` content lines.

import Foundation

public enum AssistantVisualComposer {
    public static let surfaceID = "ark.assistant.response"
    public static let maxLines = 8
    public static let maxLineLength = 160

    /// Lines extracted from free text, classified for rendering.
    public enum Line: Equatable, Sendable {
        case bullet(String)
        case step(index: Int, text: String)
        case keyValue(key: String, value: String)
        case paragraph(String)

        public var text: String {
            switch self {
            case .bullet(let text), .paragraph(let text): return text
            case .step(let index, let text): return "\(index). \(text)"
            case .keyValue(let key, let value): return "\(key): \(value)"
            }
        }
    }

    /// Builds a surface for an executed action. Prefers the executor-provided A2UI JSON when present
    /// and decodable; otherwise composes one from the outcome message.
    public static func surface(for outcome: AssistantActionOutcome, action: AssistantAction?) -> A2UISurface {
        if let json = outcome.a2uiSurfaceJSON, let provided = A2UISurface.decode(json: json) {
            return provided
        }
        let title = action?.title ?? (outcome.isFailure ? "Couldn't do that" : "Done")
        let icon = outcome.isFailure ? "exclamationmark.triangle.fill" : symbol(for: action?.category)
        return compose(title: title, body: outcome.message, icon: icon)
    }

    /// Builds a surface for a plain assistant reply. Returns `nil` when the reply has no structure
    /// worth showing (a single short sentence).
    public static func surface(forReply reply: String, title: String = "ARK") -> A2UISurface? {
        let lines = extractLines(from: reply)
        guard lines.count > 1 || reply.count > 120 else { return nil }
        return compose(title: title, body: reply, icon: "sparkles")
    }

    public static func compose(title: String, body: String, icon: String? = nil) -> A2UISurface {
        var components: [A2UIComponent] = []
        var rootChildren: [String] = []

        var headerChildren: [String] = []
        if let icon, !icon.isEmpty {
            components.append(A2UIComponent(id: "icon", component: .icon, name: .literal(icon)))
            headerChildren.append("icon")
        }
        components.append(A2UIComponent(id: "title", component: .text, text: .literal(truncate(title)), variant: "title"))
        headerChildren.append("title")
        components.append(A2UIComponent(id: "header", component: .row, children: headerChildren))
        rootChildren.append("header")

        let lines = extractLines(from: body)
        if lines.isEmpty {
            // Nothing to show beyond the title.
        } else if lines.allSatisfy({ if case .keyValue = $0 { return true } else { return false } }) {
            for (index, line) in lines.enumerated() {
                guard case .keyValue(let key, let value) = line else { continue }
                let keyID = "kv-\(index)-key"
                let valueID = "kv-\(index)-value"
                components.append(A2UIComponent(id: keyID, component: .text, text: .literal(key), variant: "secondary"))
                components.append(A2UIComponent(id: valueID, component: .text, text: .literal(value)))
                components.append(A2UIComponent(id: "kv-\(index)", component: .row, children: [keyID, valueID]))
                rootChildren.append("kv-\(index)")
            }
        } else if lines.allSatisfy({ if case .bullet = $0 { return true } else { return false } }) {
            var itemIDs: [String] = []
            for (index, line) in lines.enumerated() {
                let id = "item-\(index)"
                components.append(A2UIComponent(id: id, component: .text, text: .literal(line.text)))
                itemIDs.append(id)
            }
            components.append(A2UIComponent(id: "list", component: .list, children: itemIDs))
            rootChildren.append("list")
        } else {
            components.append(A2UIComponent(id: "divider", component: .divider))
            rootChildren.append("divider")
            for (index, line) in lines.enumerated() {
                let id = "line-\(index)"
                let variant: String? = {
                    if case .step = line { return nil }
                    if case .keyValue = line { return "secondary" }
                    return nil
                }()
                components.append(A2UIComponent(id: id, component: .text, text: .literal(line.text), variant: variant))
                rootChildren.append(id)
            }
        }

        components.insert(A2UIComponent(id: "root", component: .card, children: rootChildren), at: 0)
        return A2UISurface(surfaceID: surfaceID, root: "root", components: components)
    }

    /// Splits free text into classified, truncated lines (at most `maxLines`).
    public static func extractLines(from text: String) -> [Line] {
        let rawLines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // A single long sentence-run: split on sentence boundaries so the card shows a few lines.
        let candidates: [String] = rawLines.count == 1
            ? splitSentences(rawLines[0])
            : rawLines

        var lines: [Line] = []
        for raw in candidates {
            guard lines.count < maxLines else { break }
            lines.append(classify(raw))
        }
        return lines
    }

    static func classify(_ raw: String) -> Line {
        let line = truncate(raw)
        for prefix in ["- ", "* ", "• ", "– "] where line.hasPrefix(prefix) {
            return .bullet(String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces))
        }
        if let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }),
           let index = Int(line[..<dot]),
           line.distance(from: line.startIndex, to: dot) <= 2 {
            let rest = line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { return .step(index: index, text: rest) }
        }
        if let colon = line.firstIndex(of: ":") {
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let keyWords = key.split(separator: " ").count
            if !key.isEmpty, !value.isEmpty, keyWords <= 4, key.count <= 32, !key.contains("http") {
                return .keyValue(key: key, value: value)
            }
        }
        return .paragraph(line)
    }

    private static func splitSentences(_ text: String) -> [String] {
        guard text.count > maxLineLength else { return [text] }
        var sentences: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if ".!?".contains(character), current.count > 24 {
                sentences.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences.isEmpty ? [text] : sentences
    }

    static func truncate(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLineLength else { return trimmed }
        return String(trimmed.prefix(maxLineLength - 1)) + "…"
    }

    static func symbol(for category: AssistantAction.Category?) -> String {
        switch category {
        case .navigation: return "arrow.right.circle.fill"
        case .protection: return "shield.checkered"
        case .session: return "record.circle"
        case .signing: return "signature"
        case .requests: return "tray.full.fill"
        case .evidence: return "doc.text.magnifyingglass"
        case .account: return "person.crop.circle"
        case .assistant, .none: return "checkmark.circle.fill"
        }
    }
}

public extension A2UISurface {
    /// Attempts to decode an MCP canvas token payload (`application/a2ui+json`) into a surface.
    static func fromCanvasPayload(_ payload: String) -> A2UISurface? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return nil }
        if let surface = decode(json: trimmed) { return surface }
        // A stream of messages: pick the last one carrying components.
        if let data = trimmed.data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for message in array.reversed() {
                guard let messageData = try? JSONSerialization.data(withJSONObject: message),
                      let surface = decode(data: messageData) else { continue }
                return surface
            }
        }
        return nil
    }
}
