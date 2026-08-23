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
    public static let compactSize = CGSize(width: 188, height: 236)
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
            character(descriptor)
                .contentShape(Rectangle())
                .gesture(pushToTalkGesture)
                .accessibilityLabel("ARK pet, \(descriptor.status)")
                .accessibilityHint(descriptor.primaryActionHint)
                #if os(macOS)
                .help(descriptor.primaryActionHint)
                #endif
            statusRow(descriptor)
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
                .accessibilityLabel("Hide pet")
            }
        }
        .font(.system(size: 14, weight: .semibold))
    }

    private func character(_ descriptor: ARKPetStateDescriptor) -> some View {
        let shouldPulse = descriptor.pulses && !reduceMotion
        return AssistantPetCharacter(
            descriptor: descriptor,
            isPressed: isPressing,
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
            Text(descriptor.status)
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

// MARK: - Cartoon character

struct AssistantPetCharacter: View {
    let descriptor: ARKPetStateDescriptor
    let isPressed: Bool
    let pulse: Bool

    private var accent: Color { descriptor.color }

    var body: some View {
        ZStack {
            Ellipse()
                .fill(Color.black.opacity(0.14))
                .frame(width: 64, height: 10)
                .offset(y: 52)

            // Legs
            Capsule().fill(limbGradient).frame(width: 18, height: 32).rotationEffect(.degrees(8)).offset(x: -21, y: 38)
            Capsule().fill(limbGradient).frame(width: 18, height: 32).rotationEffect(.degrees(-8)).offset(x: 21, y: 38)

            // Arms
            Capsule().fill(limbGradient).frame(width: 18, height: 44)
                .rotationEffect(.degrees(descriptor.phase == .listening ? 28 : -16), anchor: .top)
                .offset(x: -40, y: descriptor.phase == .listening ? 6 : 14)
            Capsule().fill(limbGradient).frame(width: 18, height: 44)
                .rotationEffect(.degrees(descriptor.phase == .listening ? -28 : 16), anchor: .top)
                .offset(x: 40, y: descriptor.phase == .listening ? 6 : 14)

            // Body
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(bodyGradient)
                .frame(width: 68, height: 64)
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(.white.opacity(0.32), lineWidth: 1))
                .offset(y: 16)

            // Chest badge
            ZStack {
                Circle().fill(.white.opacity(0.9)).frame(width: 26, height: 26)
                Image(systemName: descriptor.symbol)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(accent)
            }
            .offset(y: 12)

            AssistantPetCloudHead(descriptor: descriptor)
                .offset(y: -30)
        }
        .frame(width: 112, height: 122)
        .scaleEffect(isPressed ? 0.94 : (pulse ? 1.04 : 1.0))
        .shadow(color: accent.opacity(pulse ? 0.4 : 0.22), radius: pulse ? 14 : 9, y: 5)
    }

    private var bodyGradient: LinearGradient {
        LinearGradient(colors: [accent.opacity(0.95), accent.opacity(0.62)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var limbGradient: LinearGradient {
        LinearGradient(colors: [accent.opacity(0.88), accent.opacity(0.58)], startPoint: .top, endPoint: .bottom)
    }
}

struct AssistantPetCloudHead: View {
    let descriptor: ARKPetStateDescriptor
    private var accent: Color { descriptor.color }

    var body: some View {
        ZStack {
            HStack(spacing: -16) {
                Circle().frame(width: 44, height: 44)
                Circle().frame(width: 54, height: 54)
                Circle().frame(width: 44, height: 44)
            }
            .foregroundStyle(headGradient)
            .offset(y: -7)

            RoundedRectangle(cornerRadius: 25, style: .continuous)
                .fill(headGradient)
                .frame(width: 90, height: 54)
                .overlay(RoundedRectangle(cornerRadius: 25, style: .continuous).stroke(.white.opacity(0.3), lineWidth: 1))
                .offset(y: 5)

            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(red: 0.055, green: 0.075, blue: 0.18))
                .frame(width: 58, height: 34)
                .overlay(
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.2), lineWidth: 1)
                        AssistantPetFace(descriptor: descriptor)
                    }
                )
                .offset(y: 5)
        }
        .frame(width: 98, height: 72)
    }

    private var headGradient: LinearGradient {
        LinearGradient(colors: [accent.opacity(0.98), accent.opacity(0.66)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct AssistantPetFace: View {
    let descriptor: ARKPetStateDescriptor

    var body: some View {
        Group {
            switch descriptor.phase {
            case .listening:
                HStack(spacing: 8) {
                    Circle().frame(width: 7, height: 7)
                    Image(systemName: "waveform").font(.system(size: 12, weight: .bold))
                    Circle().frame(width: 7, height: 7)
                }
            case .thinking:
                HStack(spacing: 5) {
                    Circle().frame(width: 6, height: 6)
                    Circle().frame(width: 6, height: 6)
                    Circle().frame(width: 6, height: 6)
                }
            case .speaking:
                HStack(spacing: 8) {
                    Capsule().frame(width: 6, height: 10)
                    Image(systemName: "speaker.wave.2.fill").font(.system(size: 11, weight: .bold))
                    Capsule().frame(width: 6, height: 10)
                }
            case .unavailable:
                HStack(spacing: 14) {
                    Capsule().frame(width: 8, height: 3).rotationEffect(.degrees(15))
                    Capsule().frame(width: 8, height: 3).rotationEffect(.degrees(-15))
                }
            case .ready:
                VStack(spacing: 5) {
                    HStack(spacing: 16) {
                        Capsule().frame(width: 6, height: descriptor.isMuted ? 3 : 10)
                        Capsule().frame(width: 6, height: descriptor.isMuted ? 3 : 10)
                    }
                    AssistantPetSmile()
                        .stroke(Color.white.opacity(0.94), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 14, height: descriptor.isMuted ? 2 : 6)
                }
            }
        }
        .foregroundStyle(Color.white.opacity(0.94))
        .shadow(color: descriptor.color.opacity(0.8), radius: 4)
    }
}

struct AssistantPetSmile: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}
