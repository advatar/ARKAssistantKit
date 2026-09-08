/// A compact cartoon pet that fronts the ARK assistant: push-to-talk, mute, stop-speaking, a
/// transcript strip and an A2UI visual panel. Pure SwiftUI shapes, no assets.
///
/// `ARKPetStateDescriptor` is the pure presentation mapping (testable without SwiftUI);
/// `AssistantPetWindowPolicy` tells the host how large the floating window should be.

import SwiftUI

struct AssistantPetMotionPolicy: Equatable {
    let allowsMotion: Bool
    init(reduceMotion: Bool, liveSession: Bool, quietAppearance: Bool) {
        allowsMotion = !reduceMotion && !liveSession && !quietAppearance
    }
}

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

    /// Resting offsets for the three fader caps, in points.
    ///
    /// These are *postures*, not measurements: each state has a distinct, fixed
    /// stance the caps settle into, so a state change is legible as movement
    /// without inventing an audio level the app does not have. Deterministic on
    /// purpose — nothing here is driven by signal, and nothing jitters.
    public var faderPose: [CGFloat] {
        if accent == .orange { return [0, 0, 0] }
        if isMuted && (phase == .ready || phase == .listening) { return [8, 8, 8] }
        switch phase {
        case .ready: return [-7, 0, 7]
        case .listening: return [-3, -9, -3]
        case .thinking: return [5, -5, 5]
        case .speaking: return [-9, 3, -9]
        case .unavailable: return [0, 0, 0]
        }
    }

    public init(phase: AssistantVoicePhase, isMuted: Bool, error: String?) {
        self.phase = phase
        self.isMuted = isMuted
        switch (phase, isMuted) {
        case (.listening, true):
            symbol = "mic.slash"
            accent = .gray
            status = "Muted"
            showsCancel = false
            pulses = false
            primaryActionHint = "Unmute to talk."
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
            let hasError = error?.isEmpty == false
            symbol = hasError ? "exclamationmark.triangle.fill" : "mic.slash"
            accent = hasError ? .orange : .gray
            status = hasError ? Self.shortError(error ?? "") : "Muted"
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
    private let onToggleChat: (() -> Void)?
    private let onDismiss: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("ark.assistant.quietAppearance") private var quietAppearance = false
    @State private var isPressing = false
    @State private var pulseOn = false
    @State private var breathing = false
    @State private var isHovering = false
    /// Incremented on each touch so the ripple and haptic have something to fire on.
    @State private var touchCount = 0

    /// - Parameters:
    ///   - onOpenChat: Shows the chat window. Used by affordances that should only
    ///     ever open it, such as the prompt button and the accessibility action.
    ///   - onToggleChat: Shows or hides the chat window. Falls back to `onOpenChat`
    ///     when a host cannot hide it.
    public init(
        model: AssistantChatViewModel,
        onOpenChat: (() -> Void)? = nil,
        onToggleChat: (() -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        _model = ObservedObject(wrappedValue: model)
        self.onOpenChat = onOpenChat
        self.onToggleChat = onToggleChat
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
        // Keep the board and chrome anchored while transcript/card content grows
        // below them. The background fills the host's frame instead of recentering.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(panelBackground)
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        )
        .onAppear {
            pulseOn = true
            breathing = true
        }
        .animation(allowsMotion ? .easeInOut(duration: 0.2) : nil, value: model.responseVisual)
        .transaction { if !allowsMotion { $0.animation = nil; $0.disablesAnimations = true } }
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

            if let chatAction = onToggleChat ?? onOpenChat {
                let isOpen = model.isChatWindowOpen
                Button(action: chatAction) {
                    Image(systemName: isOpen
                          ? "bubble.left.and.bubble.right.fill"
                          : "bubble.left.and.bubble.right")
                        .foregroundStyle(isOpen ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isOpen ? "Hide chat" : "Open chat")
                .accessibilityValue(isOpen ? "Showing" : "Hidden")
                .accessibilityAddTraits(isOpen ? [.isButton, .isSelected] : .isButton)
                #if os(macOS)
                .help(isOpen ? "Hide the chat window" : "Open the chat window")
                #endif
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

    /// Motion is suppressed for Reduce Motion and during a live session: a pet
    /// fidgeting in the corner while the room is being recorded is a distraction,
    /// not charm.
    private var allowsMotion: Bool {
        AssistantPetMotionPolicy(reduceMotion: reduceMotion, liveSession: model.isStudioQuiet,
                                 quietAppearance: quietAppearance).allowsMotion
    }

    private func character(_ descriptor: ARKPetStateDescriptor) -> some View {
        let shouldPulse = descriptor.phase == .listening && !descriptor.isMuted && allowsMotion
        return AssistantPetCharacter(
            descriptor: descriptor,
            isPressed: isPressing && allowsMotion,
            pulse: shouldPulse ? pulseOn : false,
            breathing: breathing && allowsMotion,
            isHovering: isHovering && allowsMotion,
            touchCount: touchCount,
            allowsMotion: allowsMotion
        )
        .onHover { hovering in
            withAnimation(allowsMotion ? .easeOut(duration: 0.18) : nil) { isHovering = hovering }
        }
        .petTouchFeedback(trigger: touchCount)
        .onChange(of: isPressing) { pressing in
            if pressing && allowsMotion { touchCount &+= 1 }
        }
        .animation(
            shouldPulse ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : nil,
            value: pulseOn
        )
        .animation(allowsMotion ? .spring(response: 0.25, dampingFraction: 0.7) : nil, value: isPressing)
        .animation(allowsMotion ? .easeInOut(duration: 0.25) : nil, value: descriptor)
        // Destroy the animated subtree on gate transitions: an already-running
        // repeatForever must not survive by retaining its previous transaction.
        .id(allowsMotion)
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
    @State private var breathPhase = false
    let descriptor: ARKPetStateDescriptor
    let isPressed: Bool
    let pulse: Bool
    var breathing: Bool = false
    var isHovering: Bool = false
    var touchCount: Int = 0
    var allowsMotion: Bool = true

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
                                .offset(y: descriptor.faderPose[index])
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
        .overlay(touchRipple)
        // Caps settle into the new stance rather than snapping, so a state change
        // reads as the pet moving instead of the view redrawing.
        .animation(allowsMotion ? .spring(response: 0.42, dampingFraction: 0.62) : nil, value: descriptor.faderPose)
        .scaleEffect(scale)
        // Hover changes the glow, never the character's position or hit target.
        .shadow(color: descriptor.color.opacity(isHovering ? 0.28 : 0), radius: 12)
        // A slow, shallow breath: enough to look awake, not enough to catch the
        // eye of someone trying to work.
        .animation(
            !allowsMotion ? nil : breathing && !isPressed
                ? .easeInOut(duration: 3.4).repeatForever(autoreverses: true)
                : .spring(response: 0.28, dampingFraction: 0.6),
            value: breathPhase
        )
        .onAppear { breathPhase = true }
    }

    private var scale: CGFloat {
        guard allowsMotion else { return 1 }
        if isPressed { return 0.955 }
        if breathing && breathPhase { return 1.012 }
        return 1
    }

    /// A single ring that expands and fades from the point of contact.
    @ViewBuilder
    private var touchRipple: some View {
        if allowsMotion {
            RoundedRectangle(cornerRadius: 18)
                .stroke(descriptor.color.opacity(0.55), lineWidth: 2)
                .scaleEffect(isPressed ? 1.06 : 0.94)
                .opacity(isPressed ? 0.9 : 0)
                .animation(.easeOut(duration: 0.45), value: isPressed)
                .animation(.easeOut(duration: 0.45), value: touchCount)
                .allowsHitTesting(false)
        }
    }
}

private extension View {
    /// A light tap on touch, where the platform supports it.
    @ViewBuilder
    func petTouchFeedback(trigger: Int) -> some View {
        #if os(iOS)
        if #available(iOS 17.0, *) {
            self.sensoryFeedback(.impact(weight: .light, intensity: 0.5), trigger: trigger)
        } else {
            self
        }
        #else
        self
        #endif
    }
}
