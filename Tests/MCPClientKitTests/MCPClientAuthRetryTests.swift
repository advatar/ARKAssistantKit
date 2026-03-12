import Foundation
import Testing
@testable import MCPClientKit

struct MCPClientAuthRetryTests {
    @Test func retriesToolCallWhenHostedMCPReturnsAuthLikeToolError() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubbedMCPURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let headerProvider = TestHeaderProvider()
        let client = MCPClient(
            config: MCPClient.Config(
                endpoint: try #require(URL(string: "https://example.test/mcp")),
                fallbackEndpoint: nil,
                clientName: "Tests",
                clientVersion: "1.0",
                protocolVersion: "2024-11-05",
                headerProvider: headerProvider
            ),
            session: session
        )

        let requestCount = LockedBox(0)
        StubbedMCPURLProtocol.handler = { request in
            let index = requestCount.withValue { value in
                value += 1
                return value
            }

            switch index {
            case 1:
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer stale-token")
                return StubbedMCPURLProtocol.response(
                    url: request.url!,
                    statusCode: 200,
                    headers: ["content-type": "application/json", "mcp-session-id": "session-1"],
                    body: #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05"}}"#
                )
            case 2:
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer stale-token")
                #expect(request.value(forHTTPHeaderField: "mcp-session-id") == "session-1")
                return StubbedMCPURLProtocol.response(
                    url: request.url!,
                    statusCode: 200,
                    headers: ["content-type": "application/json", "mcp-session-id": "session-1"],
                    body: #"{"jsonrpc":"2.0","id":2,"result":{"isError":true,"content":[{"type":"text","text":"Access token is invalid or expired"}]}}"#
                )
            case 3:
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer refreshed-token")
                #expect(request.value(forHTTPHeaderField: "mcp-session-id") == "session-1")
                return StubbedMCPURLProtocol.response(
                    url: request.url!,
                    statusCode: 200,
                    headers: ["content-type": "application/json", "mcp-session-id": "session-1"],
                    body: #"{"jsonrpc":"2.0","id":3,"result":{"isError":false,"content":[{"type":"text","text":"ok"}]}}"#
                )
            default:
                Issue.record("Unexpected request #\(index)")
                return StubbedMCPURLProtocol.response(
                    url: request.url!,
                    statusCode: 500,
                    headers: ["content-type": "application/json"],
                    body: #"{"jsonrpc":"2.0","id":999,"error":{"code":-32603,"message":"Unexpected request"}}"#
                )
            }
        }
        defer { StubbedMCPURLProtocol.reset() }

        let result = try await client.callTool(name: "list_commits", arguments: [:])

        #expect(result.isError == false)
        #expect(result.text == "ok")
        #expect(requestCount.withValue { $0 } == 3)
    }

    @Test func recognizesAuthenticationMessagesReturnedByHostedMCP() throws {
        #expect(MCPClient.isLikelyAuthenticationMessage("HTTP 401"))
        #expect(MCPClient.isLikelyAuthenticationMessage("Access token is invalid or expired"))
        #expect(MCPClient.isLikelyAuthenticationMessage("[-32003] Token invalid or insufficient scopes"))
        #expect(MCPClient.isLikelyAuthenticationMessage("Authorization required"))
        #expect(MCPClient.isLikelyAuthenticationMessage("Private-Token missing"))
        #expect(MCPClient.isLikelyAuthenticationMessage("Unknown tool") == false)
    }
}

private actor TestHeaderProvider: MCPHeaderProvider {
    func headerFields(refresh: Bool) async throws -> [String: String] {
        ["Authorization": refresh ? "Bearer refreshed-token" : "Bearer stale-token"]
    }
}

private final class StubbedMCPURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> StubResponse)?
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "example.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.withHandler({ $0 }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let stub = try handler(request)
            client?.urlProtocol(self, didReceive: stub.response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func response(url: URL, statusCode: Int, headers: [String: String], body: String) -> StubResponse {
        StubResponse(
            response: HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: headers)!,
            body: Data(body.utf8)
        )
    }

    static func reset() {
        withHandler { handler in
            handler = nil
        }
    }

    private static func withHandler<T>(_ body: (inout ((URLRequest) throws -> StubResponse)?) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&handler)
    }
}

private struct StubResponse {
    let response: HTTPURLResponse
    let body: Data
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withValue<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
