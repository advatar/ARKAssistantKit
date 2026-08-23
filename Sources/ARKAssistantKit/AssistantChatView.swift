/// Collects UI state and presentation logic for ARKAssistantKit in the shared Swift packages.
///
/// Primary declarations include `AssistantChatScreen`, `AssistantChatView`, and `View`.

import SwiftUI
import MCPClientKit

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
    @ObservedObject private var model: AssistantChatViewModel

    public init(model: AssistantChatViewModel) {
        _model = ObservedObject(wrappedValue: model)
    }

    public var body: some View {
        VStack(spacing: 12) {
            header
            canvasPanel
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
            Text("ARK Assistant")
                .font(.headline)
            Text(model.localModelText)
                .font(.caption)
                .foregroundColor(.secondary)
            if let voice = model.voiceStatusText {
                Text(voice)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if !model.liveTranscriptPreview.isEmpty {
                Text("Heard: \(model.liveTranscriptPreview)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            HStack {
                Text(model.statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Refresh") {
                    Task { await model.refreshTools() }
                }
                .buttonStyle(.borderless)
            }
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
                    ForEach(model.messages) { message in
                        messageRow(message)
                            .id(message.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .background(chatBackground)
            .cornerRadius(8)
            .ark_onChangeCompat(model.messages.count) {
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
        guard let action = model.actionCatalog.action(named: name) else { return }
        Task {
            await model.performAction(AssistantActionInvocation(action: action, source: .text))
        }
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
                .onSubmit {
                    model.sendCurrentInput()
                }

            Button {
                // Push-to-talk uses press/release; this action is intentionally empty.
            } label: {
                Image(systemName: model.isRecording ? "mic.fill" : "mic")
            }
            .buttonStyle(.bordered)
            #if os(macOS)
            .help("Hold to talk")
            #endif
            .disabled(!model.canUseVoice)
            .onLongPressGesture(minimumDuration: 0.0, maximumDistance: 20, pressing: { pressing in
                if pressing {
                    model.startPushToTalk()
                } else {
                    model.stopPushToTalk()
                }
            }, perform: {})

            Button("Send") {
                model.sendCurrentInput()
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
