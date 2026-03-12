import Foundation
import Testing
@testable import ARKAssistantKit

import MCPClientKit

struct MCPDefaultToolArgumentsTests {
    @Test func fillsProjectIdentifierWhenToolSupportsIt() throws {
        let tool = MCPToolDefinition(
            name: "list_commits",
            description: "List project commits",
            inputSchemaJSON: #"{"type":"object","properties":{"project_id":{"type":"string"},"ref_name":{"type":"string"}}}"#
        )

        let merged = MCPDefaultToolArguments.mergedArguments(
            for: tool,
            arguments: ["ref_name": "main"],
            defaults: MCPDefaultToolContext(projectID: "showntell/ark")
        )

        #expect(merged["project_id"] as? String == "showntell/ark")
        #expect(merged["ref_name"] as? String == "main")
    }

    @Test func keepsExplicitProjectIdentifier() throws {
        let tool = MCPToolDefinition(
            name: "list_commits",
            description: "List project commits",
            inputSchemaJSON: #"{"type":"object","properties":{"project_id":{"type":"string"}}}"#
        )

        let merged = MCPDefaultToolArguments.mergedArguments(
            for: tool,
            arguments: ["project_id": "override/project"],
            defaults: MCPDefaultToolContext(projectID: "showntell/ark")
        )

        #expect(merged["project_id"] as? String == "override/project")
    }

    @Test func leavesArgumentsUntouchedWhenToolHasNoProjectIdentifier() throws {
        let tool = MCPToolDefinition(
            name: "list_namespaces",
            description: "List namespaces",
            inputSchemaJSON: #"{"type":"object","properties":{"search":{"type":"string"}}}"#
        )
        let original: [String: Any] = ["search": "ark"]

        let merged = MCPDefaultToolArguments.mergedArguments(
            for: tool,
            arguments: original,
            defaults: MCPDefaultToolContext(projectID: "showntell/ark")
        )

        #expect((merged as NSDictionary).isEqual(to: original))
    }
}
