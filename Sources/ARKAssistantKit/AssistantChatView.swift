import SwiftUI

public struct AssistantChatScreen: View {
    @StateObject private var model: AssistantChatViewModel

    public init(endpoint: URL? = nil) {
        _model = StateObject(wrappedValue: AssistantChatViewModel(endpoint: endpoint))
    }

    public var body: some View {
        AssistantChatView(model: model)
    }
}

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
                if !model.canvasTokens.isEmpty {
                    Button("Clear") {
                        model.clearCanvasTokens()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
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
                                Text(token.payload)
                                    .font(.caption.monospaced())
                                    .foregroundColor(.primary)
                                    .textSelection(.enabled)
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

    private func messageRow(_ message: AssistantChatViewModel.Message) -> some View {
        HStack {
            if message.role == .user { Spacer() }
            Text(message.text)
                .font(.body)
                .foregroundColor(.primary)
                .padding(8)
                .background(message.role == .user ? Color.blue.opacity(0.2) : Color.gray.opacity(0.15))
                .cornerRadius(8)
                .frame(maxWidth: 300, alignment: message.role == .user ? .trailing : .leading)
            if message.role == .assistant { Spacer() }
        }
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
