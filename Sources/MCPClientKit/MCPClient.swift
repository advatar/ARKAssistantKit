/// Coordinates MCP Client responsibilities for ARKAssistantKit in the shared Swift packages.
///
/// Primary declarations include `MCPToolDefinition`, `MCPToolCallResult`, and `MCPClient`.

import Foundation

/// Describes the MCP header provider contract used by the ARKAssistantKit module.
public protocol MCPHeaderProvider: Sendable {
    func headerFields(refresh: Bool) async throws -> [String: String]
}

/// Defines the MCP Tool Definition value used by ARKAssistantKit in the shared Swift packages.
public struct MCPToolDefinition: Sendable, Identifiable {
    public let id = UUID()
    public let name: String
    public let description: String
    public let inputSchemaJSON: String

    public init(name: String, description: String, inputSchemaJSON: String) {
        self.name = name
        self.description = description
        self.inputSchemaJSON = inputSchemaJSON
    }
}

/// Models the MCP Tool Call Result data carried through ARKAssistantKit in the shared Swift packages.
public struct MCPToolCallResult: Sendable {
    public struct ContentItem: Sendable, Equatable {
        public let type: String
        public let text: String?
        public let uri: String?
        public let mimeType: String?

        public init(type: String, text: String?, uri: String?, mimeType: String?) {
            self.type = type
            self.text = text
            self.uri = uri
            self.mimeType = mimeType
        }
    }

    public let text: String
    public let isError: Bool
    public let content: [ContentItem]

    public init(text: String, isError: Bool, content: [ContentItem] = []) {
        self.text = text
        self.isError = isError
        self.content = content
    }
}

/// Coordinates MCP Client responsibilities for ARKAssistantKit in the shared Swift packages.
public actor MCPClient {
    public struct Config: Sendable {
        public let endpoint: URL
        public let fallbackEndpoint: URL?
        public let clientName: String
        public let clientVersion: String
        public let protocolVersion: String
        public let headerProvider: MCPHeaderProvider?

        public init(
            endpoint: URL,
            fallbackEndpoint: URL?,
            clientName: String,
            clientVersion: String,
            protocolVersion: String,
            headerProvider: MCPHeaderProvider? = nil
        ) {
            self.endpoint = endpoint
            self.fallbackEndpoint = fallbackEndpoint
            self.clientName = clientName
            self.clientVersion = clientVersion
            self.protocolVersion = protocolVersion
            self.headerProvider = headerProvider
        }

        public static func `default`() -> Config {
            let endpoints = MCPClient.resolveEndpoints()
            return Config(
                endpoint: endpoints.primary,
                fallbackEndpoint: endpoints.fallback,
                clientName: "ARK",
                clientVersion: "0.1.0",
                protocolVersion: "2024-11-05",
                headerProvider: nil
            )
        }
    }

    public enum MCPError: Error, LocalizedError {
        case invalidResponse
        case serverError(String)
        case requestFailed(String)
        case decodeFailed(String)

        public var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "Invalid MCP response"
            case .serverError(let message):
                return "MCP error: \(message)"
            case .requestFailed(let message):
                return "MCP request failed: \(message)"
            case .decodeFailed(let message):
                return "MCP decode failed: \(message)"
            }
        }
    }

    private let config: Config
    private let session: URLSession
    private var nextId: Int = 1
    private var initialized = false
    private var activeEndpoint: URL
    private var sessionId: String?

    public init(config: Config = .default(), session: URLSession = .shared) {
        self.config = config
        self.session = session
        self.activeEndpoint = config.endpoint
    }

    public static func resolveEndpoints() -> (primary: URL, fallback: URL?) {
        let env = ProcessInfo.processInfo.environment

        if let raw = env["ARK_MCP_ENDPOINT"], let url = URL(string: raw) {
            return (url, nil)
        }

        let mode = env["ARK_MCP_MODE"] ?? UserDefaults.standard.string(forKey: "ARK_MCP_MODE") ?? "auto"
        let legacyEndpoint = resolveLegacyEndpoint(env: env)

        if mode == "inprocess" || mode == "legacy" {
            return (legacyEndpoint, nil)
        }

        if let appEndpoint = resolveAppEndpoint(env: env) {
            if appEndpoint.absoluteString != legacyEndpoint.absoluteString {
                return (appEndpoint, legacyEndpoint)
            }
            return (appEndpoint, nil)
        }

        return (legacyEndpoint, nil)
    }

    private static func resolveLegacyEndpoint(env: [String: String]) -> URL {
        let host = env["ARK_MCP_HOST"] ?? UserDefaults.standard.string(forKey: "ARK_MCP_HOST") ?? "127.0.0.1"
        let port = env["ARK_MCP_PORT"] ?? UserDefaults.standard.string(forKey: "ARK_MCP_PORT") ?? "7331"
        return URL(string: "http://\(host):\(port)/mcp")!
    }

    private static func resolveAppEndpoint(env: [String: String]) -> URL? {
        #if os(iOS)
        let appGroupId: String? = nil
        #else
        let appGroupId = env["ARK_APP_GROUP_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        #endif

        let base: URL
        if let appGroupId,
           !appGroupId.isEmpty,
           let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) {
            base = groupURL.appendingPathComponent("Library/Application Support", isDirectory: true)
        } else {
            base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        }

        let configURL = base.appendingPathComponent("ARK/mcp/config.json")
        guard let data = try? Data(contentsOf: configURL) else { return nil }

        struct AppConfig: Decodable {
            let host: String
            let port: Int
        }

        guard let config = try? JSONDecoder().decode(AppConfig.self, from: data) else { return nil }
        return URL(string: "http://\(config.host):\(config.port)/mcp")
    }

    public func listTools() async throws -> [MCPToolDefinition] {
        try await ensureInitialized()
        let response = try await sendRequest(method: "tools/list", params: [:])
        guard let result = response["result"] as? [String: Any],
              let tools = result["tools"] as? [[String: Any]] else {
            throw MCPError.decodeFailed("Missing tools")
        }

        return tools.compactMap { tool in
            guard let name = tool["name"] as? String else { return nil }
            let description = tool["description"] as? String ?? ""
            let schemaObject = tool["inputSchema"] ?? [:]
            let schemaJSON = Self.encodeJSON(schemaObject) ?? "{}"
            return MCPToolDefinition(name: name, description: description, inputSchemaJSON: schemaJSON)
        }
    }

    public func callTool(name: String, arguments: [String: Any]) async throws -> MCPToolCallResult {
        try await ensureInitialized()
        let params: [String: Any] = [
            "name": name,
            "arguments": arguments
        ]
        let response = try await sendRequest(method: "tools/call", params: params)
        let result = try Self.parseToolCallResult(from: response)

        if config.headerProvider != nil,
           result.isError,
           Self.isLikelyAuthenticationMessage(result.text) {
            let retryResponse = try await sendRequest(
                method: "tools/call",
                params: params,
                forceAuthRefresh: true
            )
            return try Self.parseToolCallResult(from: retryResponse)
        }

        return result
    }

    private func ensureInitialized() async throws {
        if initialized { return }
        _ = try await sendRequest(method: "initialize", params: [
            "protocolVersion": config.protocolVersion,
            "capabilities": [:],
            "clientInfo": [
                "name": config.clientName,
                "version": config.clientVersion
            ]
        ])
        initialized = true
    }

    private func sendRequest(
        method: String,
        params: [String: Any],
        forceAuthRefresh: Bool = false
    ) async throws -> [String: Any] {
        if let fallback = config.fallbackEndpoint {
            if activeEndpoint.absoluteString == config.endpoint.absoluteString,
               let response = try await sendRequestWithFallback(
                primary: activeEndpoint,
                fallback: fallback,
                method: method,
                params: params,
                forceAuthRefresh: forceAuthRefresh
               ) {
                return response
            }
            if activeEndpoint.absoluteString == fallback.absoluteString,
               let response = try await sendRequestWithFallback(
                primary: activeEndpoint,
                fallback: config.endpoint,
                method: method,
                params: params,
                forceAuthRefresh: forceAuthRefresh
               ) {
                return response
            }
        }

        return try await sendRequest(
            method: method,
            params: params,
            endpoint: activeEndpoint,
            forceAuthRefresh: forceAuthRefresh
        )
    }

    private func sendRequestWithFallback(
        primary: URL,
        fallback: URL,
        method: String,
        params: [String: Any],
        forceAuthRefresh: Bool
    ) async throws -> [String: Any]? {
        do {
            return try await sendRequest(
                method: method,
                params: params,
                endpoint: primary,
                forceAuthRefresh: forceAuthRefresh
            )
        } catch {
            guard shouldRetry(error) else { throw error }
        }

        do {
            let previousSessionId = sessionId
            sessionId = nil
            let response: [String: Any]
            do {
                response = try await sendRequest(
                    method: method,
                    params: params,
                    endpoint: fallback,
                    forceAuthRefresh: forceAuthRefresh
                )
            } catch {
                sessionId = previousSessionId
                throw error
            }
            activeEndpoint = fallback
            if method != "initialize" {
                initialized = false
            }
            return response
        } catch {
            throw error
        }
    }

    private func sendRequest(
        method: String,
        params: [String: Any],
        endpoint: URL,
        forceAuthRefresh: Bool
    ) async throws -> [String: Any] {
        let id = nextId
        nextId += 1

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ]

        let body = try JSONSerialization.data(withJSONObject: payload, options: [])
        return try await performRequest(
            body: body,
            endpoint: endpoint,
            allowAuthRefresh: !forceAuthRefresh,
            forceAuthRefresh: forceAuthRefresh
        )
    }

    private func performRequest(
        body: Data,
        endpoint: URL,
        allowAuthRefresh: Bool,
        forceAuthRefresh: Bool
    ) async throws -> [String: Any] {
        let request = try await buildRequest(endpoint: endpoint, body: body, refreshAuth: forceAuthRefresh)
        do {
            return try await execute(request: request)
        } catch let error as MCPError {
            if allowAuthRefresh,
               error.isAuthenticationFailure,
               config.headerProvider != nil {
                let retryRequest = try await buildRequest(endpoint: endpoint, body: body, refreshAuth: true)
                return try await execute(request: retryRequest)
            }
            throw error
        }
    }

    private func buildRequest(endpoint: URL, body: Data, refreshAuth: Bool) async throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionId {
            request.setValue(sessionId, forHTTPHeaderField: "mcp-session-id")
        }
        if let headerProvider = config.headerProvider {
            let headers = try await headerProvider.headerFields(refresh: refreshAuth)
            for (field, value) in headers {
                request.setValue(value, forHTTPHeaderField: field)
            }
        }
        return request
    }

    private func execute(request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MCPError.invalidResponse
        }

        if let returnedSessionId = http.value(forHTTPHeaderField: "mcp-session-id"),
           !returnedSessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sessionId = returnedSessionId
        }

        if !(200..<300).contains(http.statusCode) {
            throw Self.httpError(statusCode: http.statusCode, data: data)
        }

        let json = try Self.decodeResponseObject(from: data)
        if let error = json["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Unknown error"
            let code = error["code"] as? Int
            if let code {
                throw MCPError.serverError("[\(code)] \(message)")
            }
            throw MCPError.serverError(message)
        }

        return json
    }

    private func shouldRetry(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost, .notConnectedToInternet, .timedOut:
                return true
            default:
                return false
            }
        }
        return false
    }

    static func decodeResponseObject(from data: Data) throws -> [String: Any] {
        if let object = try? Self.parseJSONObject(from: data) {
            return object
        }
        if let eventData = Self.extractEventStreamJSONData(from: data),
           let object = try? Self.parseJSONObject(from: eventData) {
            return object
        }
        throw MCPError.invalidResponse
    }

    static func extractEventStreamJSONData(from data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var payloadLines: [String] = []

        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            guard line.hasPrefix("data:") else { continue }
            let value = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            payloadLines.append(value)
        }

        guard !payloadLines.isEmpty else { return nil }
        return payloadLines.joined(separator: "\n").data(using: .utf8)
    }

    private static func parseJSONObject(from data: Data) throws -> [String: Any]? {
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        return object as? [String: Any]
    }

    static func parseToolCallResult(from response: [String: Any]) throws -> MCPToolCallResult {
        guard let result = response["result"] as? [String: Any] else {
            throw MCPError.decodeFailed("Missing tool result")
        }

        let isError = result["isError"] as? Bool ?? false
        let content = result["content"] as? [[String: Any]] ?? []
        let text = Self.renderContentText(from: content)
        return MCPToolCallResult(
            text: text,
            isError: isError,
            content: Self.parseContentItems(from: content)
        )
    }

    static func isLikelyAuthenticationMessage(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }

        let authIndicators = [
            "http 401",
            "http 403",
            "access token is invalid or expired",
            "authentication required",
            "authorization required",
            "invalid or expired",
            "invalid token",
            "missing token",
            "private-token",
            "refresh token",
            "token expired",
            "token invalid",
            "unauthorized",
            "insufficient scope",
            "insufficient scopes"
        ]

        return authIndicators.contains { normalized.contains($0) }
    }

    private static func httpError(statusCode: Int, data: Data) -> MCPError {
        if let payload = try? decodeResponseObject(from: data),
           let error = payload["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.isEmpty {
            return .requestFailed("HTTP \(statusCode): \(message)")
        }
        return .requestFailed("HTTP \(statusCode)")
    }

    private static func encodeJSON(_ value: Any) -> String? {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: []) {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    private static func parseContentItems(from items: [[String: Any]]) -> [MCPToolCallResult.ContentItem] {
        items.map { item in
            MCPToolCallResult.ContentItem(
                type: item["type"] as? String ?? "",
                text: item["text"] as? String,
                uri: item["uri"] as? String,
                mimeType: item["mimeType"] as? String
            )
        }
    }

    private static func renderContentText(from items: [[String: Any]]) -> String {
        var lines: [String] = []
        for item in items {
            let type = item["type"] as? String ?? ""
            switch type {
            case "text":
                if let text = item["text"] as? String {
                    lines.append(text)
                }
            case "resource":
                let uri = item["uri"] as? String ?? ""
                let mime = item["mimeType"] as? String ?? ""
                lines.append("[resource uri=\(uri) mime=\(mime)]")
                if let text = item["text"] as? String {
                    lines.append(text)
                }
            case "image":
                let mime = item["mimeType"] as? String ?? ""
                lines.append("[image mime=\(mime)]")
            case "audio":
                let mime = item["mimeType"] as? String ?? ""
                lines.append("[audio mime=\(mime)]")
            default:
                lines.append("[content type=\(type)]")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// Extends `MCPClient.MCPError` with behavior used by the ARKAssistantKit module.
private extension MCPClient.MCPError {
    var isAuthenticationFailure: Bool {
        switch self {
        case .serverError(let message):
            return MCPClient.isLikelyAuthenticationMessage(message)
        case .requestFailed(let message):
            return MCPClient.isLikelyAuthenticationMessage(message)
        default:
            return false
        }
    }
}
