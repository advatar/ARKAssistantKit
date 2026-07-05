/// Collects UI state and presentation logic for ARKAssistantKit in the shared Swift packages.
///
/// Primary declarations include `AssistantChatViewModel` and `WeakMainActorModel`.

import Foundation
import Combine
import SwiftUI
import AVFoundation

import MCPClientKit

/// Implements the assistant Chat View Model type for ARKAssistantKit in the shared Swift packages.
@MainActor
public final class AssistantChatViewModel: ObservableObject {
    public struct Message: Identifiable, Equatable {
        public enum Role: String {
            case user
            case assistant
        }

        public let id: UUID
        public let role: Role
        public var text: String
        public let timestamp: Date

        public init(id: UUID = UUID(), role: Role, text: String, timestamp: Date = Date()) {
            self.id = id
            self.role = role
            self.text = text
            self.timestamp = timestamp
        }
    }

    public struct CanvasToken: Identifiable, Equatable {
        public let id: UUID
        public let source: String
        public let payload: String
        public let timestamp: Date

        public init(id: UUID = UUID(), source: String, payload: String, timestamp: Date = Date()) {
            self.id = id
            self.source = source
            self.payload = payload
            self.timestamp = timestamp
        }
    }

    @Published public private(set) var messages: [Message] = []
    @Published public var inputText: String = ""
    @Published public private(set) var isResponding = false
    @Published public private(set) var statusText: String = "MCP: not connected"
    @Published public private(set) var localModelText: String = "Model: unavailable"
    @Published public private(set) var lastError: String?
    @Published public private(set) var isRecording = false
    @Published public private(set) var isTranscribingVoice = false
    @Published public private(set) var voiceStatusText: String?
    @Published public private(set) var liveTranscriptPreview: String = ""
    @Published public private(set) var canvasTokens: [CanvasToken] = []

    private var mcpClient: MCPClient
    private var toolCache: [MCPToolDefinition] = []
    private let micAudioEngine = AssistantMicAudioEngine()
    private let speechToTextEngine = AssistantSpeechToTextEngine()
    private let speechSpeaker = AssistantSpeechSpeaker()
    private let localLLMClient = AssistantLocalLLMClient()
    private var voiceTask: Task<Void, Never>?
    private var voicePartialText: String = ""
    private var voiceFinalText: String = ""

    private let clientName: String
    private let clientVersion: String
    private let protocolVersion: String
    private let conversationContext: String?
    private let defaultToolContext: MCPDefaultToolContext

    public init(
        endpoint: URL? = nil,
        clientName: String = "ARK",
        clientVersion: String = "0.1.0",
        protocolVersion: String = "2024-11-05",
        contextSummary: String? = nil,
        defaultProjectID: String? = nil,
        headerProvider: MCPHeaderProvider? = nil
    ) {
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.protocolVersion = protocolVersion
        self.conversationContext = contextSummary?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.defaultToolContext = MCPDefaultToolContext(projectID: defaultProjectID)
        self.mcpClient = MCPClient(
            config: AssistantChatViewModel.makeConfig(
                endpoint: endpoint,
                clientName: clientName,
                clientVersion: clientVersion,
                protocolVersion: protocolVersion,
                headerProvider: headerProvider
            )
        )
        updateLocalModelStatus()

        #if os(iOS)
        if endpoint == nil {
            statusText = "MCP: configure endpoint"
            return
        }
        #endif

        Task { await self.refreshTools() }
    }

    public func setEndpoint(_ endpoint: URL?, headerProvider: MCPHeaderProvider? = nil) {
        mcpClient = MCPClient(
            config: AssistantChatViewModel.makeConfig(
                endpoint: endpoint,
                clientName: clientName,
                clientVersion: clientVersion,
                protocolVersion: protocolVersion,
                headerProvider: headerProvider
            )
        )
        toolCache.removeAll(keepingCapacity: true)
        lastError = nil

        #if os(iOS)
        if endpoint == nil {
            statusText = "MCP: configure endpoint"
            return
        }
        #endif

        Task { await self.refreshTools() }
    }

    private static func makeConfig(
        endpoint: URL?,
        clientName: String,
        clientVersion: String,
        protocolVersion: String,
        headerProvider: MCPHeaderProvider?
    ) -> MCPClient.Config {
        let endpoints = MCPClient.resolveEndpoints()
        let resolved = endpoint ?? endpoints.primary
        return MCPClient.Config(
            endpoint: resolved,
            fallbackEndpoint: endpoint == nil ? endpoints.fallback : nil,
            clientName: clientName,
            clientVersion: clientVersion,
            protocolVersion: protocolVersion,
            headerProvider: headerProvider
        )
    }

    public var canSend: Bool {
        localLLMClient.canAttemptResponse
            && !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isResponding
    }

    public var canUseVoice: Bool {
        localLLMClient.canAttemptResponse
            && !isResponding
            && !isTranscribingVoice
    }

    public func refreshTools() async {
        statusText = "MCP: connecting…"
        do {
            let tools = try await mcpClient.listTools()
            toolCache = tools
            statusText = "MCP: \(tools.count) tools"
        } catch {
            statusText = "MCP: unavailable"
            reportError(error.localizedDescription, context: "refreshTools")
        }
    }

    public func sendCurrentInput() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        inputText = ""
        submitUserMessage(trimmed, triggeredByVoice: false)
    }

    public func startPushToTalk() {
        guard canUseVoice else { return }
        guard !isRecording else { return }
        voiceTask?.cancel()
        voiceTask = Task { await beginVoiceCapture() }
    }

    public func stopPushToTalk() {
        guard isRecording else { return }
        voiceTask?.cancel()
        voiceTask = Task { await endVoiceCaptureAndSubmit() }
    }

    public func clearCanvasTokens() {
        canvasTokens.removeAll()
    }

    private func updateLocalModelStatus() {
        localModelText = localLLMClient.statusText()
    }

    private func submitUserMessage(_ text: String, triggeredByVoice: Bool) {
        lastError = nil
        appendMessage(role: .user, text: text)
        Task { await self.generateResponse(for: text, speakResponse: triggeredByVoice) }
    }

    private func beginVoiceCapture() async {
        lastError = nil
        voiceStatusText = nil
        liveTranscriptPreview = ""
        voicePartialText = ""
        voiceFinalText = ""

        let micGranted = await requestMicrophoneAccessIfNeeded()
        guard micGranted else {
            reportError("Microphone access is required for push-to-talk.", context: "beginVoiceCapture")
            voiceStatusText = "Mic permission denied"
            return
        }

        let speechGranted = await speechToTextEngine.requestSpeechPermission()
        guard speechGranted else {
            reportError("Speech recognition permission is required for push-to-talk.", context: "beginVoiceCapture")
            voiceStatusText = "Speech permission denied"
            return
        }

        do {
            try await speechToTextEngine.start(
                preferredLocale: .current,
                onPartial: { [weak self] text in
                    guard let self else { return }
                    self.voicePartialText = text
                    self.liveTranscriptPreview = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if self.isRecording {
                        self.voiceStatusText = "Listening…"
                    }
                },
                onFinal: { [weak self] text in
                    guard let self else { return }
                    self.voiceFinalText = text
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        self.liveTranscriptPreview = trimmed
                    }
                },
                onDownloadProgress: { [weak self] progress in
                    guard let self else { return }
                    if progress != nil {
                        self.voiceStatusText = "Downloading speech assets…"
                    } else if self.isRecording {
                        self.voiceStatusText = "Listening…"
                    }
                }
            )

            try micAudioEngine.start { [weak self] buffer in
                guard let self else { return }
                do {
                    try self.speechToTextEngine.handleAudioBuffer(buffer)
                } catch {
                    self.reportError("Audio conversion failed: \(error.localizedDescription)", context: "micAudioEngine")
                }
            }

            isRecording = true
            voiceStatusText = "Listening…"
        } catch {
            micAudioEngine.stop()
            await speechToTextEngine.stop()
            reportError("Unable to start voice capture: \(error.localizedDescription)", context: "beginVoiceCapture")
            voiceStatusText = "Recording failed"
        }
    }

    private func endVoiceCaptureAndSubmit() async {
        isRecording = false
        isTranscribingVoice = true
        voiceStatusText = "Transcribing…"
        defer { isTranscribingVoice = false }

        micAudioEngine.stop()
        await speechToTextEngine.stop()

        let candidate = !voiceFinalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? voiceFinalText
            : voicePartialText
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        liveTranscriptPreview = ""
        voiceFinalText = ""
        voicePartialText = ""

        guard !trimmed.isEmpty else {
            voiceStatusText = "No speech detected"
            return
        }

        voiceStatusText = nil
        submitUserMessage(trimmed, triggeredByVoice: true)
    }

    private func requestMicrophoneAccessIfNeeded() async -> Bool {
        let current = AVCaptureDevice.authorizationStatus(for: .audio)
        switch current {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    private func generateResponse(for userText: String, speakResponse: Bool) async {
        updateLocalModelStatus()
        guard localLLMClient.canAttemptResponse else {
            reportError("Assistant requires a local model: Gemma, SwiftLM, Ollama, or Apple Foundation Models.", context: "generateResponse")
            appendMessage(role: .assistant, text: "Assistant requires a local model: Gemma, SwiftLM, Ollama, or Apple Foundation Models.")
            return
        }

        isResponding = true
        defer { isResponding = false }

        do {
            let forceToolRefresh = shouldHandleToolInventoryRequest(userText)
            let tools = forceToolRefresh
                ? try await mcpClient.listTools()
                : (toolCache.isEmpty ? try await mcpClient.listTools() : toolCache)
            if toolCache.isEmpty || forceToolRefresh {
                toolCache = tools
                statusText = "MCP: \(tools.count) tools"
            }

            if shouldHandleToolInventoryRequest(userText) {
                let response = formatToolInventoryResponse(tools: tools)
                appendMessage(role: .assistant, text: response)
                if speakResponse {
                    await speechSpeaker.speak(response)
                }
                return
            }

            let assistantId = UUID()
            messages.append(Message(id: assistantId, role: .assistant, text: "", timestamp: Date()))
            let response = try await generateLocalLLMResponse(userText: userText, tools: tools)
            updateMessage(id: assistantId, text: response.text)
            localModelText = "Model: \(response.providerLabel)"
            if speakResponse, let reply = messages.first(where: { $0.id == assistantId })?.text {
                await speechSpeaker.speak(reply)
            }
        } catch {
            reportError(error.localizedDescription, context: "generateResponse")
            appendMessage(role: .assistant, text: "Error: \(error.localizedDescription)")
        }
    }

    private func appendMessage(role: Message.Role, text: String) {
        messages.append(Message(role: role, text: text))
        if role == .assistant, text.hasPrefix("Error:") {
            Self.logConsole("Assistant message: \(text)")
        }
    }

    private func reportError(_ message: String, context: String) {
        lastError = message
        Self.logConsole("Error [\(context)]: \(message)")
    }

    nonisolated private static func logConsole(_ message: String) {
        print("[ARKAssistant] \(message)")
    }

    private func updateMessage(id: UUID, text: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text = text
    }

    private func truncateForPrompt(_ text: String, maxChars: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxChars { return trimmed }
        guard maxChars > 3 else { return String(trimmed.prefix(maxChars)) }
        return String(trimmed.prefix(maxChars - 3)) + "..."
    }

    private func buildFoundationPrompt(with userText: String) -> String {
        let maxHistoryChars = 2_000
        let maxMessageChars = 500
        let maxUserChars = 1_800

        var historyMessages = messages
            .filter { !$0.text.isEmpty }
        if historyMessages.last?.role == .user, historyMessages.last?.text == userText {
            historyMessages.removeLast()
        }

        var lines: [String] = []
        lines.reserveCapacity(8)

        var budget = maxHistoryChars
        for message in historyMessages.reversed() {
            let label = message.role == .user ? "User" : "Assistant"
            let shortText = truncateForPrompt(message.text, maxChars: maxMessageChars)
            guard !shortText.isEmpty else { continue }
            let line = "\(label): \(shortText)"
            // If we're out of budget, stop including older messages.
            if line.count + 1 > budget { break }
            lines.append(line)
            budget -= (line.count + 1)
            if lines.count >= 8 { break }
        }

        let history = lines.reversed().joined(separator: "\n")
        let trimmedUserText = truncateForPrompt(userText, maxChars: maxUserChars)
        let contextBlock = {
            guard let conversationContext, !conversationContext.isEmpty else {
                return "Project context: (none)"
            }
            return "Project context:\n\(conversationContext)"
        }()

        return """
        You are ARK Assistant. Keep responses concise and actionable.
        Chat naturally. Use MCP tools only when ARK data or actions are needed.
        Treat project context as the default target for MCP tool arguments unless the user specifies a different project.

        \(contextBlock)

        Conversation history (most recent last, may be truncated):
        \(history.isEmpty ? "(none)" : history)

        User: \(trimmedUserText)
        Assistant:
        """
    }

    private func shouldHandleToolInventoryRequest(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }

        let triggers = [
            "which tools",
            "what tools",
            "list tools",
            "show tools",
            "available tools",
            "mcp tools",
            "tool list",
            "tools do you have"
        ]

        return triggers.contains { normalized.contains($0) }
    }

    private func formatToolInventoryResponse(tools: [MCPToolDefinition]) -> String {
        guard !tools.isEmpty else {
            return "No MCP tools are currently available from the connected server."
        }

        let sorted = tools.sorted { $0.name < $1.name }
        let lines = sorted.map { tool -> String in
            let shortDesc = truncateForPrompt(tool.description, maxChars: 96)
            if let args = MCPToolFormatting.compactArgsSummary(from: tool.inputSchemaJSON), !args.isEmpty {
                return "- `\(tool.name)` | \(shortDesc) | args: \(truncateForPrompt(args, maxChars: 120))"
            }
            return "- `\(tool.name)` | \(shortDesc)"
        }

        return (["Available MCP tools (\(sorted.count)):" ] + lines).joined(separator: "\n")
    }

    private func generateLocalLLMResponse(userText: String, tools: [MCPToolDefinition]) async throws -> AssistantLocalLLMClient.Response {
        let prompt = buildFoundationPrompt(with: userText)
        let toolHint = tools.isEmpty
            ? "No MCP tools are currently connected."
            : "Connected MCP tools: \(tools.prefix(20).map(\.name).joined(separator: ", "))."
        return try await localLLMClient.response(
            prompt: "\(prompt)\n\n\(toolHint)",
            instructions: """
            You are an ARK assistant. Keep responses concise and actionable.
            For greetings and general chat, reply directly.
            If the user asks for ARK data or actions and a tool would be required, say which connected MCP tool/action is needed instead of pretending you executed it.
            Treat project context as the default target for tool arguments unless the user specifies a different project.
            """
        )
    }

    private func captureA2UITokens(from result: MCPToolCallResult) {
        guard !result.content.isEmpty else { return }
        var newTokens: [CanvasToken] = []
        for item in result.content {
            guard Self.isLikelyA2UI(item) else { continue }
            guard let rawPayload = item.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawPayload.isEmpty else { continue }
            let source = item.uri?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? item.mimeType?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? item.type
            newTokens.append(CanvasToken(source: source, payload: rawPayload))
        }

        guard !newTokens.isEmpty else { return }
        for token in newTokens {
            if let previous = canvasTokens.last,
               previous.source == token.source,
               previous.payload == token.payload {
                continue
            }
            canvasTokens.append(token)
        }
        if canvasTokens.count > 60 {
            canvasTokens.removeFirst(canvasTokens.count - 60)
        }
    }

    nonisolated private static func isLikelyA2UI(_ item: MCPToolCallResult.ContentItem) -> Bool {
        let type = item.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mime = item.mimeType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let uri = item.uri?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if type.contains("a2ui") || mime.contains("a2ui") || uri.contains("a2ui") {
            return true
        }
        if mime.contains("json"), uri.hasPrefix("a2://") {
            return true
        }
        return false
    }

}

/// Implements the weak Main Actor Model type for ARKAssistantKit in the shared Swift packages.
private final class WeakMainActorModel: @unchecked Sendable {
    weak var value: AssistantChatViewModel?

    init(_ value: AssistantChatViewModel) {
        self.value = value
    }
}
