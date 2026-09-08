/// Collects UI state and presentation logic for ARKAssistantKit in the shared Swift packages.
///
/// Primary declarations include `AssistantChatScreen`, `AssistantChatView`, and `View`.

import SwiftUI
import MCPClientKit

/// Shared studio voice. Evidence claims still come from host actions, never this persona.
public enum SessionAssistant {
    public static let name = "Session Assistant"
    public static let instructions = """
    You are ARK's Session Assistant: a calm, discreet assistant engineer beside the mixing desk.
    Help people get the room ready, check what happened, and wrap up their session.
    Use short, plain studio language. Be warm without mascot chatter, hype, or unsolicited creative direction.
    Never claim to hear audio, see the DAW, know a participant, or have performed an action without supplied evidence.
    Distinguish observed track metadata, instrument-classifier suggestions, self-declared roles, and participant confirmations.
    An instrument match can suggest whom to ask; it cannot identify who performed a take.
    State capture gaps, timing uncertainty, missing data and unresolved attribution plainly. Never turn an inference into a fact.
    Cryptographic integrity does not prove authorship or independently verify a self-claimed identity.
    Ask for confirmation through the available review flow. Never sign, assign credit, start capture or change a session autonomously.
    Only describe capabilities and actions available on this device. Do not imply shared chat history across devices.
    """
}

/// Explicit navigation, not an automatically generated claim about session readiness.
struct SessionAssistantStartingPoints: View {
    @ObservedObject var model: AssistantChatViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Beside you at the desk.").font(.headline)
            Text("Prepare the room, review the work, then check what still needs your attention.")
                .font(.caption).foregroundStyle(.secondary)
            destination("Get the room ready", symbol: "person.2", action: "navigation.liveSession")
            #if os(iOS)
            destination("Check what happened", symbol: "clock", action: "protection.projectStatus")
            #else
            destination("Check what happened", symbol: "clock", action: "navigation.eventHistory")
            #endif
            destination("Review before wrapping up", symbol: "checklist", action: "requests.pending")
            destination("View proofs", symbol: "checkmark.seal", action: "navigation.evidence")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func destination(_ title: String, symbol: String, action: String) -> some View {
        if model.actionCatalog.action(named: action) != nil, model.actionExecutor != nil {
            Button { model.submitAction(named: action) } label: {
                Label(title, systemImage: symbol).font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 3)
            }
            .disabled(model.isResponding)
            .accessibilityIdentifier("session-assistant-\(action)")
        }
    }
}

/// Presents the assistant Chat Screen interface for ARKAssistantKit in the shared Swift packages.
public struct AssistantChatScreen: View {
    @StateObject private var model: AssistantChatViewModel

    public init(
        endpoint: URL? = nil,
        contextSummary: String? = nil,
        defaultProjectID: String? = nil,
        headerProvider: MCPHeaderProvider? = nil,
        actionCatalog: AssistantActionCatalog = AssistantActionCatalog(actions: []),
        actionExecutor: AssistantActionExecutor? = nil
    ) {
        _model = StateObject(
            wrappedValue: AssistantChatViewModel(
                endpoint: endpoint,
                contextSummary: contextSummary,
                defaultProjectID: defaultProjectID,
                headerProvider: headerProvider,
                actionCatalog: actionCatalog,
                actionExecutor: actionExecutor
            )
        )
    }

    public var body: some View {
        AssistantChatView(model: model)
    }
}

/// Presents the assistant Chat View interface for ARKAssistantKit in the shared Swift packages.
public struct AssistantChatView: View {
    @AppStorage("ark.assistant.quietAppearance") private var quietAppearance = false
    @ObservedObject private var model: AssistantChatViewModel
    private let compactConversation: Bool
    private let voiceInputEnabled: Bool
    @FocusState private var inputFocused: Bool

    public init(model: AssistantChatViewModel, compactConversation: Bool = false, voiceInputEnabled: Bool = true) {
        _model = ObservedObject(wrappedValue: model)
        self.compactConversation = compactConversation
        self.voiceInputEnabled = voiceInputEnabled
    }

    public var body: some View {
        VStack(spacing: 12) {
            header
            if !compactConversation { canvasPanel }
            messageList
            inputRow
        }
        .padding(12)
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !compactConversation {
                Text(SessionAssistant.name)
                    .font(.headline)
            }
            Text(model.localModelText)
                .font(.caption)
                .foregroundColor(.secondary)
            if let voice = model.voiceStatusText {
                Text(voice)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Toggle("Spoken replies", isOn: $model.spokenRepliesEnabled)
                .font(.caption)
                .disabled(model.isStudioQuiet)
                .onChange(of: model.spokenRepliesEnabled) { enabled in
                    if !enabled { model.stopSpeaking() }
                }
            Toggle("Quiet appearance", isOn: $quietAppearance)
                .font(.caption)
                .help("Keep the companion still, including outside Live Session.")
            if !voiceInputEnabled || model.isStudioQuiet {
                Text("Voice chat is paused during Live Session. You can still type.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.liveTranscriptPreview.isEmpty {
                Text("Heard: \(model.liveTranscriptPreview)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            if !compactConversation { HStack {
                Text(model.statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Refresh") {
                    Task { await model.refreshTools() }
                }
                .buttonStyle(.borderless)
            } }
            if let error = model.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if model.messages.isEmpty {
                        SessionAssistantStartingPoints(model: model)
                            .padding(12)
                    }
                    ForEach(model.messages) { message in
                        if compactConversation, let visual = message.visual {
                            A2UINativeRenderer(surface: visual, onAction: handleVisualAction)
                                .padding(12)
                                .disabled(model.isResponding)
                                .accessibilityIdentifier("assistant-response-card")
                                .id(message.id)
                        } else {
                            messageRow(message)
                                .id(message.id)
                        }
                    }
                    if model.isResponding {
                        ProgressView("Thinking…")
                            .accessibilityIdentifier("assistant-thinking")
                    }
                }
                .padding(.vertical, 4)
            }
            .background(chatBackground)
            .cornerRadius(8)
            .ark_onChangeCompat(model.messages) {
                guard let last = model.messages.last else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var chatBackground: Color {
        #if os(macOS)
        return Color(nsColor: .controlBackgroundColor)
        #else
        return Color(uiColor: .secondarySystemBackground)
        #endif
    }

    private var canvasPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Canvas")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if !model.canvasTokens.isEmpty || model.responseVisual != nil {
                    Button("Clear") {
                        model.clearCanvasTokens()
                        model.clearResponseVisual()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }

            if let visual = model.responseVisual {
                A2UINativeRenderer(surface: visual, onAction: handleVisualAction)
            }

            if model.canvasTokens.isEmpty {
                Text("Waiting for A2UI tokens from MCP tools.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.canvasTokens.suffix(10)) { token in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(token.source)
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(.secondary)
                                if let surface = A2UISurface.fromCanvasPayload(token.payload) {
                                    A2UINativeRenderer(surface: surface, onAction: handleVisualAction)
                                } else {
                                    Text(token.payload)
                                        .font(.caption.monospaced())
                                        .foregroundColor(.primary)
                                        .textSelection(.enabled)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color.gray.opacity(0.12))
                            .cornerRadius(8)
                        }
                    }
                }
                .frame(minHeight: 90, maxHeight: 180)
            }
        }
        .padding(10)
        .background(chatBackground)
        .cornerRadius(8)
    }

    /// Button presses inside an A2UI surface map onto catalog actions by name.
    private func handleVisualAction(_ name: String) {
        model.submitAction(named: name)
    }

    private func messageRow(_ message: AssistantChatViewModel.Message) -> some View {
        HStack {
            if message.role == .user { Spacer() }
            messageText(message.text)
                .font(.body)
                .foregroundColor(.primary)
                .padding(8)
                .background(message.role == .user ? Color.blue.opacity(0.2) : Color.gray.opacity(0.15))
                .cornerRadius(8)
                .frame(maxWidth: 300, alignment: message.role == .user ? .trailing : .leading)
            if message.role == .assistant { Spacer() }
        }
    }

    private func messageText(_ text: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            return Text(attributed)
        }
        return Text(text)
    }

    @ViewBuilder
    private var inputField: some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            TextField("Ask ARK…", text: $model.inputText, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
        } else {
            TextField("Ask ARK…", text: $model.inputText)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            inputField
                .focused($inputFocused)
                .accessibilityIdentifier("assistant-input")
                .onSubmit {
                    model.sendCurrentInput()
                    if compactConversation { inputFocused = false }
                }

            Button {
                // Push-to-talk uses press/release; this action is intentionally empty.
            } label: {
                Image(systemName: model.isRecording ? "mic.fill" : "mic")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(model.isMicrophoneMuted ? "Microphone muted" : "Hold to talk")
            .accessibilityIdentifier("assistant-microphone")
            #if os(macOS)
            .help("Hold to talk")
            #endif
            .disabled(!model.canUseVoice || !voiceInputEnabled || model.isMicrophoneMuted)
            .onLongPressGesture(minimumDuration: 0.0, maximumDistance: 20, pressing: { pressing in
                if pressing {
                    guard voiceInputEnabled else { return }
                    model.startPushToTalk()
                } else {
                    model.stopPushToTalk()
                }
            }, perform: {})

            Button("Send") {
                model.sendCurrentInput()
                if compactConversation { inputFocused = false }
            }
            .disabled(!model.canSend)
        }
    }
}

/// Extends `View` with behavior used by ARKAssistantKit in the shared Swift packages.
private extension View {
    @ViewBuilder
    func ark_onChangeCompat<Value: Equatable>(_ value: Value, perform: @escaping () -> Void) -> some View {
        #if os(macOS)
        onChange(of: value) { _, _ in
            perform()
        }
        #else
        if #available(iOS 17.0, *) {
            onChange(of: value) { _, _ in
                perform()
            }
        } else {
            onChange(of: value) { _ in
                perform()
            }
        }
        #endif
    }
}
