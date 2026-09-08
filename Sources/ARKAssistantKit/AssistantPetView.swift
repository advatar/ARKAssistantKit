/// A compact cartoon pet that fronts the ARK assistant: push-to-talk, mute, stop-speaking, a
/// transcript strip and an A2UI visual panel. Pure SwiftUI shapes, no assets.
///
/// `ARKPetStateDescriptor` is the pure presentation mapping (testable without SwiftUI);
/// `AssistantPetWindowPolicy` tells the host how large the floating window should be.

import SwiftUI

// MARK: - State descriptor

/// Pure mapping from (phase, muted, error) to what the pet shows.
public struct ARKPetStateDescriptor: Equatable, Sendable {
    public enum Accent: String, Equatable, Sendable {
        case blue
        case red
        case purple
        case green
        case gray
        case orange
    }

    public let phase: AssistantVoicePhase
    public let isMuted: Bool
    public let symbol: String
    public let accent: Accent
    public let status: String
    public let showsCancel: Bool
    public let pulses: Bool
    /// Accessibility/help text for the primary (push-to-talk) control.
    public let primaryActionHint: String

    public init(phase: AssistantVoicePhase, isMuted: Bool, error: String?) {
        self.phase = phase
        self.isMuted = isMuted
        switch (phase, isMuted) {
        case (.listening, _):
            symbol = "mic.fill"
            accent = .red
            status = "Listening"
            showsCancel = false
            pulses = true
            primaryActionHint = "Release to send."
        case (.thinking, _):
            symbol = "sparkles"
            accent = .purple
            status = "Thinking"
            showsCancel = false
            pulses = true
            primaryActionHint = "ARK is working on it."
        case (.speaking, _):
            symbol = "speaker.wave.2.fill"
            accent = .green
            status = "Speaking"
            showsCancel = true
            pulses = true
            primaryActionHint = "Stop to interrupt."
        case (.unavailable, _):
            symbol = "exclamationmark.triangle.fill"
            accent = .orange
            status = error.map { Self.shortError($0) } ?? "Unavailable"
            showsCancel = false
            pulses = false
            primaryActionHint = "Voice is unavailable."
        case (.ready, true):
            symbol = "mic.slash"
            accent = .gray
            status = "Muted"
            showsCancel = false
            pulses = false
            primaryActionHint = "Unmute to talk."
        case (.ready, false):
            if let error, !error.isEmpty {
                symbol = "exclamationmark.triangle.fill"
                accent = .orange
                status = Self.shortError(error)
                showsCancel = false
                pulses = false
                primaryActionHint = "Hold to try again."
            } else {
                symbol = "waveform"
                accent = .blue
                status = "Ready"
                showsCancel = false
                pulses = false
                primaryActionHint = "Hold to talk."
            }
        }
    }

    static func shortError(_ error: String) -> String {
        let trimmed = error.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 40 else { return trimmed }
        return String(trimmed.prefix(39)) + "…"
    }

    public var color: Color {
        switch accent {
        case .blue: return .blue
        case .red: return .red
        case .purple: return .purple
        case .green: return .green
        case .gray: return .gray
        case .orange: return .orange
        }
    }
}

// MARK: - Window policy

public struct AssistantPetWindowPolicy {
    public static let compactSize = CGSize(width: 240, height: 270)
    public static let expandedSize = CGSize(width: 300, height: 360)
    public static let visualSize = CGSize(width: 420, height: 560)

    @MainActor
    public static func size(for model: AssistantChatViewModel) -> CGSize {
        if model.responseVisual != nil { return visualSize }
        let hasTranscript = model.messages.contains { !$0.text.isEmpty }
        return hasTranscript ? expandedSize : compactSize
    }
}

// MARK: - Pet view

public struct AssistantPetView: View {
    @ObservedObject private var model: AssistantChatViewModel
    private let onOpenChat: (() -> Void)?
    private let onDismiss: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPressing = false
    @State private var pulseOn = false

    public init(model: AssistantChatViewModel, onOpenChat: (() -> Void)? = nil, onDismiss: (() -> Void)? = nil) {
        _model = ObservedObject(wrappedValue: model)
        self.onOpenChat = onOpenChat
        self.onDismiss = onDismiss
    }

    private var descriptor: ARKPetStateDescriptor {
        ARKPetStateDescriptor(phase: model.voicePhase, isMuted: model.isMicrophoneMuted, error: model.lastError)
    }

    public var body: some View {
        let descriptor = descriptor
        VStack(spacing: 8) {
            topBar(descriptor)
            Text(SessionAssistant.name).font(.headline)
            character(descriptor)
                .contentShape(Rectangle())
                .gesture(pushToTalkGesture)
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Session Assistant, \(model.isStudioQuiet ? "Quiet during Live Session" : descriptor.status)")
                .accessibilityHint(model.isStudioQuiet ? "Open chat to type." : descriptor.primaryActionHint)
                .accessibilityAction {
                    if model.isStudioQuiet { onOpenChat?() }
                    else if model.isRecording { model.stopPushToTalk() }
                    else { model.startPushToTalk() }
                }
                #if os(macOS)
                .help(descriptor.primaryActionHint)
                #endif
            statusRow(descriptor)
            if model.messages.isEmpty, let onOpenChat {
                Button("How can I help this session?", action: onOpenChat)
                    .font(.caption)
            }
            transcriptStrip
            if let visual = model.responseVisual {
                visualPanel(visual)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(panelBackground)
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        )
        .onAppear { pulseOn = true }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.responseVisual)
    }

    // MARK: Sections

    private func topBar(_ descriptor: ARKPetStateDescriptor) -> some View {
        HStack(spacing: 8) {
            Button {
                model.toggleMicrophoneMuted()
            } label: {
                Image(systemName: model.isMicrophoneMuted ? "mic.slash.fill" : "mic")
                    .foregroundStyle(model.isMicrophoneMuted ? Color.gray : Color.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(model.isMicrophoneMuted ? "Unmute microphone" : "Mute microphone")
            #if os(macOS)
            .help(model.isMicrophoneMuted ? "Microphone off — click to unmute" : "Turn microphone off")
            #endif

            Spacer()

            if descriptor.showsCancel {
                Button {
                    model.stopSpeaking()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .foregroundStyle(Color.green)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Stop speaking")
            }

            if let onOpenChat {
                Button(action: onOpenChat) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .foregroundStyle(Color.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Open chat")
            }

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Hide Session Assistant")
            }
        }
        .font(.system(size: 14, weight: .semibold))
    }

    private func character(_ descriptor: ARKPetStateDescriptor) -> some View {
        let shouldPulse = descriptor.phase == .listening && !reduceMotion && !model.isStudioQuiet
        return AssistantPetCharacter(
            descriptor: descriptor,
            isPressed: isPressing && !model.isStudioQuiet,
            pulse: shouldPulse ? pulseOn : false
        )
        .animation(
            shouldPulse ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default,
            value: pulseOn
        )
        .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7), value: isPressing)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: descriptor)
    }

    private func statusRow(_ descriptor: ARKPetStateDescriptor) -> some View {
        HStack(spacing: 6) {
            Image(systemName: descriptor.symbol)
                .font(.system(size: 11, weight: .bold))
            Text(model.isStudioQuiet ? "Quiet · Live Session" : descriptor.status)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(descriptor.color)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(descriptor.color.opacity(0.14)))
    }

    private var lastUserLine: String? {
        if !model.liveTranscriptPreview.isEmpty { return model.liveTranscriptPreview }
        return model.messages.last(where: { $0.role == .user && !$0.text.isEmpty })?.text
    }

    private var lastAssistantLine: String? {
        model.messages.last(where: { $0.role == .assistant && !$0.text.isEmpty })?.text
    }

    @ViewBuilder
    private var transcriptStrip: some View {
        if lastUserLine != nil || lastAssistantLine != nil {
            VStack(alignment: .leading, spacing: 3) {
                if let user = lastUserLine {
                    Label(user, systemImage: "person.fill")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(2)
                }
                if let assistant = lastAssistantLine {
                    Label(assistant, systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(Color.primary)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.gray.opacity(0.12)))
        }
    }

    private func visualPanel(_ surface: A2UISurface) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Visual")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.secondary)
                Spacer()
                Button("Clear") { model.clearResponseVisual() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            ScrollView {
                A2UINativeRenderer(surface: surface) { name in
                    guard let action = model.actionCatalog.action(named: name) else { return }
                    Task { await model.performAction(AssistantActionInvocation(action: action, source: .pet)) }
                }
            }
            .frame(maxHeight: 260)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Gesture

    private var pushToTalkGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !isPressing else { return }
                isPressing = true
                if model.voicePhase == .speaking {
                    model.stopSpeaking()
                }
                model.startPushToTalk()
            }
            .onEnded { _ in
                isPressing = false
                model.stopPushToTalk()
            }
    }

    private var panelBackground: Color {
        #if os(macOS)
        return Color(nsColor: .windowBackgroundColor)
        #else
        return Color(uiColor: .systemBackground)
        #endif
    }
}

// MARK: - Compact console companion

struct AssistantPetCharacter: View {
    let descriptor: ARKPetStateDescriptor
    let isPressed: Bool
    let pulse: Bool

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Circle().fill(descriptor.color).frame(width: 7, height: 7)
                Text("ARK").font(.system(.caption2, design: .monospaced).weight(.bold))
                Spacer()
                Image(systemName: descriptor.symbol).foregroundStyle(descriptor.color)
            }
            HStack(spacing: 18) {
                ForEach(0..<3) { index in
                    Capsule().fill(Color.secondary.opacity(0.25))
                        .frame(width: 3, height: 38)
                        .overlay(alignment: .center) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.primary.opacity(0.8))
                                .frame(width: 13, height: 7)
                                .offset(y: CGFloat(index - 1) * 7)
                        }
                }
            }
            // This is a state lamp, not an invented audio level meter.
            Capsule().fill(descriptor.color.opacity(pulse ? 0.9 : 0.35))
                .frame(height: 3)
        }
        .padding(14)
        .frame(width: 130, height: 122)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color.secondary.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.secondary.opacity(0.3)))
        .scaleEffect(isPressed ? 0.98 : 1)
    }
}
