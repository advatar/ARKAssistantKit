import SwiftUI

public struct AssistantFloatingPushToTalkButton: View {
    @ObservedObject private var model: AssistantChatViewModel
    private let size: CGFloat
    private let holdThresholdSeconds: Double
    private let onTap: () -> Void

    @State private var isPressing = false
    @State private var didStartRecording = false
    @State private var holdTask: Task<Void, Never>?

    public init(
        model: AssistantChatViewModel,
        size: CGFloat = 56,
        holdThresholdSeconds: Double = 0.12,
        onTap: @escaping () -> Void
    ) {
        _model = ObservedObject(wrappedValue: model)
        self.size = size
        self.holdThresholdSeconds = holdThresholdSeconds
        self.onTap = onTap
    }

    public var body: some View {
        content
            .contentShape(Circle())
            .gesture(pressGesture)
            .accessibilityLabel("Assistant push to talk")
            .accessibilityHint("Tap to open chat. Press and hold to talk.")
    }

    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                handlePressBegan()
            }
            .onEnded { _ in
                handlePressEnded()
            }
    }

    private var content: some View {
        ZStack {
            Circle()
                .fill(backgroundFill)
                .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 8)

            Image(systemName: model.isRecording ? "mic.fill" : "mic")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .overlay(
            Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1)
        )
        .opacity(model.canUseVoice ? 1.0 : 0.7)
    }

    private var backgroundFill: AnyShapeStyle {
        if model.isRecording || didStartRecording {
            return AnyShapeStyle(LinearGradient(
                colors: [Color.red.opacity(0.95), Color.orange.opacity(0.95)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
        }
        if isPressing {
            return AnyShapeStyle(LinearGradient(
                colors: [Color.blue.opacity(0.95), Color.cyan.opacity(0.95)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
        }
        return AnyShapeStyle(LinearGradient(
            colors: [Color.black.opacity(0.65), Color.black.opacity(0.45)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        ))
    }

    private func handlePressBegan() {
        guard !isPressing else { return }
        isPressing = true
        didStartRecording = false

        holdTask?.cancel()
        holdTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(holdThresholdSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard isPressing else { return }
                guard model.canUseVoice else { return }
                didStartRecording = true
                model.startPushToTalk()
            }
        }
    }

    private func handlePressEnded() {
        isPressing = false
        holdTask?.cancel()
        holdTask = nil

        if didStartRecording {
            didStartRecording = false
            model.stopPushToTalk()
            onTap()
        } else {
            onTap()
        }
    }
}
