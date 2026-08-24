/// Documents the MCP Bridge Tools source in ARKAssistantKit in the shared Swift packages.
///
/// Primary declarations include `MCPToolCatalog`, `MCPListToolsArguments`, `MCPListToolsTool`, and `MCPCallToolArguments`.

import Foundation

import MCPClientKit

/// Models the MCP default tool context data carried through the ARKAssistantKit module.
struct MCPDefaultToolContext: Sendable {
    let projectID: String?

    init(projectID: String? = nil) {
        let trimmed = projectID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.projectID = (trimmed?.isEmpty == false) ? trimmed : nil
    }
}

/// Provides the MCP default tool arguments namespace used by the ARKAssistantKit module.
enum MCPDefaultToolArguments {
    static func mergedArguments(
        for tool: MCPToolDefinition?,
        arguments: [String: Any],
        defaults: MCPDefaultToolContext
    ) -> [String: Any] {
        guard let projectID = defaults.projectID,
              supportsProjectID(tool),
              !containsNonEmptyValue(forKey: "project_id", in: arguments) else {
            return arguments
        }

        var merged = arguments
        merged["project_id"] = projectID
        return merged
    }

    private static func supportsProjectID(_ tool: MCPToolDefinition?) -> Bool {
        guard let tool,
              let data = tool.inputSchemaJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let properties = object["properties"] as? [String: Any] else {
            return false
        }
        return properties["project_id"] != nil
    }

    private static func containsNonEmptyValue(forKey key: String, in arguments: [String: Any]) -> Bool {
        guard let value = arguments[key] else { return false }
        if let string = value as? String {
            return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }
}

#if canImport(FoundationModels)
import FoundationModels

/// Implements the MCP Tool Catalog type for ARKAssistantKit in the shared Swift packages.
@available(iOS 26.0, macOS 26.0, *)
actor MCPToolCatalog: Sendable {
    private let mcp: MCPClient
    private var cachedTools: [MCPToolDefinition]?

    init(mcp: MCPClient, seed: [MCPToolDefinition]? = nil) {
        self.mcp = mcp
        self.cachedTools = seed
    }

    func tools() async throws -> [MCPToolDefinition] {
        if let cachedTools {
            return cachedTools
        }
        let tools = try await mcp.listTools()
        cachedTools = tools
        return tools
    }
}

/// Defines the MCP List Tools Arguments value used by ARKAssistantKit in the shared Swift packages.
@available(iOS 26.0, macOS 26.0, *)
@Generable
struct MCPListToolsArguments {
    @Guide(description: "Search query. Empty => tool count only.")
    var query: String?

    @Guide(description: "Max tools to return (1-25).")
    var maxResults: Int?
}

/// Defines the MCP List Tools Tool value used by ARKAssistantKit in the shared Swift packages.
@available(iOS 26.0, macOS 26.0, *)
struct MCPListToolsTool: FoundationModels.Tool {
    typealias Arguments = MCPListToolsArguments
    typealias Output = String

    let name: String = "mcp_list_tools"
    let description: String = "Search MCP tools and show compact args."

    private let catalog: MCPToolCatalog

    init(catalog: MCPToolCatalog) {
        self.catalog = catalog
    }

    func call(arguments: MCPListToolsArguments) async throws -> String {
        let tools: [MCPToolDefinition]
        do {
            tools = try await catalog.tools()
        } catch {
            return [
                "mcp.isError=true",
                "mcp.operation=list_tools",
                "mcp.error=\(error.localizedDescription)",
                "Try again shortly."
            ].joined(separator: "\n")
        }
        let query = arguments.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let maxResults = max(1, min(arguments.maxResults ?? 8, 15))

        if query.isEmpty {
            return "MCP tools available: \(tools.count). Provide a query (e.g. \"current project\", \"proof\", \"share invite\")."
        }

        let q = query.lowercased()
        let matches = tools
            .map { tool -> (tool: MCPToolDefinition, score: Int) in
                let name = tool.name.lowercased()
                let desc = tool.description.lowercased()
                var score = 0
                if name == q { score += 100 }
                if name.contains(q) { score += 50 }
                if desc.contains(q) { score += 10 }
                return (tool, score)
            }
            .filter { $0.score > 0 }
            .sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                return a.tool.name < b.tool.name
            }
            .prefix(maxResults)
            .map { $0.tool }

        if matches.isEmpty {
            return "No MCP tools matched query: \"\(query)\". Try a different query."
        }

        let lines: [String] = matches.map { tool in
            let argsSummaryRaw = MCPToolFormatting.compactArgsSummary(from: tool.inputSchemaJSON) ?? "none"
            let argsSummary = MCPToolFormatting.truncate(argsSummaryRaw, max: 140)
            let shortDesc = MCPToolFormatting.truncate(tool.description, max: 120)
            return "- \(tool.name): \(shortDesc) | args: \(argsSummary)"
        }

        return (["Matched \(matches.count) of \(tools.count) tools for query \"\(query)\":"] + lines).joined(separator: "\n")
    }
}

/// Defines the MCP Call Tool Arguments value used by ARKAssistantKit in the shared Swift packages.
@available(iOS 26.0, macOS 26.0, *)
@Generable
struct MCPCallToolArguments {
    @Guide(description: "Exact MCP tool name (use mcp_list_tools if unsure).")
    var name: String

    @Guide(description: "Tool args as JSON object string. Use {} for none.")
    var json: String?
}

/// Defines the MCP Call Tool Tool value used by ARKAssistantKit in the shared Swift packages.
@available(iOS 26.0, macOS 26.0, *)
struct MCPCallToolTool: FoundationModels.Tool {
    typealias ResultObserver = @Sendable (MCPToolCallResult) -> Void
    typealias Arguments = MCPCallToolArguments
    typealias Output = String

    let name: String = "mcp_call_tool"
    let description: String = "Call an MCP tool by name."

    private let mcp: MCPClient
    private let catalog: MCPToolCatalog?
    private let resultObserver: ResultObserver?
    private let defaults: MCPDefaultToolContext

    init(
        mcp: MCPClient,
        catalog: MCPToolCatalog? = nil,
        defaults: MCPDefaultToolContext = MCPDefaultToolContext(),
        resultObserver: ResultObserver? = nil
    ) {
        self.mcp = mcp
        self.catalog = catalog
        self.defaults = defaults
        self.resultObserver = resultObserver
    }

    func call(arguments: MCPCallToolArguments) async throws -> String {
        let requestedName = arguments.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedName.isEmpty else {
            return [
                "mcp.isError=true",
                "mcp.operation=call_tool",
                "mcp.error=Tool name is empty",
                "Use mcp_list_tools to find available tools."
            ].joined(separator: "\n")
        }

        let rawJSON = arguments.json ?? "{}"
        let decodedArguments = MCPToolFormatting.decodeArguments(from: rawJSON)
        let resolvedName = await resolvedToolName(for: requestedName)
        guard let toolName = resolvedName else {
            return unknownToolResponse(for: requestedName)
        }
        let toolDefinition = await resolvedToolDefinition(for: toolName)
        let dict = MCPDefaultToolArguments.mergedArguments(
            for: toolDefinition,
            arguments: decodedArguments,
            defaults: defaults
        )

        do {
            let result = try await mcp.callTool(name: toolName, arguments: dict)
            resultObserver?(result)
            return MCPToolFormatting.formatToolResult(isError: result.isError, text: result.text)
        } catch {
            return [
                "mcp.isError=true",
                "mcp.operation=call_tool",
                "mcp.tool=\(requestedName)",
                "mcp.error=\(error.localizedDescription)",
                "Use mcp_list_tools to discover the correct tool name and arguments."
            ].joined(separator: "\n")
        }
    }

    private func resolvedToolName(for requestedName: String) async -> String? {
        guard let catalog else {
            return requestedName
        }

        guard let tools = try? await catalog.tools() else {
            return requestedName
        }

        if tools.contains(where: { $0.name == requestedName }) {
            return requestedName
        }

        let requestedLower = requestedName.lowercased()
        if let exactInsensitive = tools.first(where: { $0.name.lowercased() == requestedLower }) {
            return exactInsensitive.name
        }

        if let containsMatch = tools.first(where: { $0.name.lowercased().contains(requestedLower) }) {
            return containsMatch.name
        }

        return nil
    }

    private func resolvedToolDefinition(for toolName: String) async -> MCPToolDefinition? {
        guard let catalog,
              let tools = try? await catalog.tools() else {
            return nil
        }
        return tools.first(where: { $0.name == toolName })
    }

    private func unknownToolResponse(for requestedName: String) -> String {
        [
            "mcp.isError=true",
            "mcp.operation=call_tool",
            "mcp.tool=\(requestedName)",
            "mcp.error=Unknown tool: \(requestedName)",
            "Call mcp_list_tools with a short query to find the exact tool name first."
        ].joined(separator: "\n")
    }
}

/// Defines MCP Tool Formatting cases used by ARKAssistantKit in the shared Swift packages.
enum MCPToolFormatting {
    private static let maxToolOutputChars = 6_000

    static func decodeArguments(from rawJSON: String) -> [String: Any] {
        let trimmed = rawJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "null" {
            return [:]
        }

        if let dict = decodeDictionary(from: trimmed) {
            return dict
        }

        if let unwrapped = decodeJSONString(from: trimmed) {
            let inner = unwrapped.trimmingCharacters(in: .whitespacesAndNewlines)
            if inner.isEmpty || inner == "null" {
                return [:]
            }
            if let dict = decodeDictionary(from: inner) {
                return dict
            }
        }

        let preview = trimmed.prefix(200)
        print("[ARKAssistantKit] Invalid tool arguments json=\(preview)")
        return [:]
    }

    private static func decodeDictionary(from json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []) else { return nil }
        return object as? [String: Any]
    }

    private static func decodeJSONString(from json: String) -> String? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(String.self, from: data)
    }

    static func compactArgsSummary(from inputSchemaJSON: String) -> String? {
        guard let data = inputSchemaJSON.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else { return nil }
        guard let properties = object["properties"] as? [String: Any], !properties.isEmpty else { return nil }
        let required = Set(object["required"] as? [String] ?? [])

        func renderType(_ value: Any?) -> String {
            guard let dict = value as? [String: Any] else { return "any" }
            let type = (dict["type"] as? String) ?? "any"
            switch type {
            case "string":
                return "string"
            case "integer":
                return "int"
            case "number":
                return "number"
            case "boolean":
                return "bool"
            case "array":
                let items = (dict["items"] as? [String: Any])?["type"] as? String
                if let items {
                    return "[\(items)]"
                }
                return "[any]"
            case "object":
                return "object"
            default:
                return type
            }
        }

        let parts = properties.keys.sorted().map { key -> String in
            let marker = required.contains(key) ? "*" : ""
            let type = renderType(properties[key])
            return "\(key)\(marker): \(type)"
        }
        return parts.joined(separator: ", ")
    }

    static func truncate(_ text: String, max: Int) -> String {
        if text.count <= max { return text }
        return String(text.prefix(max - 3)) + "..."
    }

    static func formatToolResult(isError: Bool, text: String) -> String {
        // People read this in the chat: no protocol headers, just the result.
        let header = isError ? "The remote tool reported a problem." : ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return isError ? header : "The remote tool returned no output."
        }

        if trimmed.count <= maxToolOutputChars {
            return [header, trimmed].filter { !$0.isEmpty }.joined(separator: "\n")
        }

        let prefix = String(trimmed.prefix(maxToolOutputChars))
        let omitted = trimmed.count - maxToolOutputChars
        return [
            header,
            prefix,
            "… (\(omitted) more characters omitted)"
        ].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
#endif
