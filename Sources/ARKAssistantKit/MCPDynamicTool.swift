/// Documents the MCP Dynamic Tool source in ARKAssistantKit in the shared Swift packages.
///
/// Primary declarations include `MCPDynamicTool`.

import Foundation

import MCPClientKit

#if canImport(FoundationModels)
import FoundationModels

/// Defines the MCP Dynamic Tool value used by ARKAssistantKit in the shared Swift packages.
@available(iOS 26.0, macOS 26.0, *)
struct MCPDynamicTool: FoundationModels.Tool {
    let name: String
    let description: String
    let parameters: GenerationSchema

    private let mcp: MCPClient
    private let mcpToolName: String

    typealias Arguments = GeneratedContent
    typealias Output = String

    init(mcp: MCPClient, tool: MCPToolDefinition) {
        self.mcp = mcp
        self.mcpToolName = tool.name
        self.name = tool.name

        let argsSummary = MCPDynamicTool.compactArgsSummary(from: tool.inputSchemaJSON)
        if let argsSummary, !argsSummary.isEmpty {
            self.description = """
            \(tool.description)

            Args: \(argsSummary) (* required)
            Provide arguments as a JSON object string in the `json` parameter.
            """
        } else {
            self.description = """
            \(tool.description)

            No arguments.
            """
        }

        self.parameters = GenerationSchema(
            type: GeneratedContent.self,
            properties: [
                .init(
                    name: "json",
                    description: "JSON object string of tool arguments matching the MCP inputSchema.",
                    type: String.self
                )
            ]
        )
    }

    func call(arguments: GeneratedContent) async throws -> String {
        let rawJSON = (try? arguments.value(String.self, forProperty: "json")) ?? ""
        let dict = decodeArguments(from: rawJSON)
        let result = try await mcp.callTool(name: mcpToolName, arguments: dict)
        let header = "mcp.isError=\(result.isError)"
        if result.text.isEmpty {
            return header
        }
        return ([header, result.text]).joined(separator: "\n")
    }

    private func decodeArguments(from rawJSON: String) -> [String: Any] {
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

    private func decodeDictionary(from json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []) else { return nil }
        return object as? [String: Any]
    }

    private func decodeJSONString(from json: String) -> String? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(String.self, from: data)
    }

    private static func compactArgsSummary(from inputSchemaJSON: String) -> String? {
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
}
#endif

