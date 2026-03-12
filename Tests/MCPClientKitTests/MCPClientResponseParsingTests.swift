import Foundation
import Testing
@testable import MCPClientKit

struct MCPClientResponseParsingTests {
    @Test func decodesPlainJSONResponse() throws {
        let data = Data(#"{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}"#.utf8)

        let payload = try MCPClient.decodeResponseObject(from: data)

        let result = try #require(payload["result"] as? [String: Any])
        let tools = try #require(result["tools"] as? [Any])
        #expect(tools.isEmpty)
    }

    @Test func decodesEventStreamResponse() throws {
        let data = Data(
            """
            event: message
            data: {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05"}}

            """.utf8
        )

        let payload = try MCPClient.decodeResponseObject(from: data)

        let result = try #require(payload["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2024-11-05")
    }

    @Test func extractsEventStreamJSONData() throws {
        let data = Data(
            """
            event: message
            data: {"jsonrpc":"2.0"}

            """.utf8
        )

        let extracted = try #require(MCPClient.extractEventStreamJSONData(from: data))
        #expect(String(decoding: extracted, as: UTF8.self) == #"{"jsonrpc":"2.0"}"#)
    }
}
