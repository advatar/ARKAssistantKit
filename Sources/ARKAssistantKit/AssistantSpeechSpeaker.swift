import AVFoundation

@MainActor
final class AssistantSpeechSpeaker: NSObject {
    private let synthesizer = AVSpeechSynthesizer()
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private var activeUtteranceID: ObjectIdentifier?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, language: String? = nil) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        stop()
        configureAudioSessionForSpeech()

        let requestedLanguage = language?.replacingOccurrences(of: "_", with: "-")
            ?? Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        let voice = AVSpeechSynthesisVoice(language: requestedLanguage)
            ?? AVSpeechSynthesisVoice(language: "en-US")

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        await withCheckedContinuation { continuation in
            activeUtteranceID = ObjectIdentifier(utterance)
            finishContinuation = continuation
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        finishCurrentUtterance()
    }

    private func configureAudioSessionForSpeech() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("[ARKAssistantKit] speech session error: \(error)")
        }
        #endif
    }

    private func finishCurrentUtterance(matching utteranceID: ObjectIdentifier? = nil) {
        guard utteranceID == nil || utteranceID == activeUtteranceID else { return }
        let continuation = finishContinuation
        finishContinuation = nil
        activeUtteranceID = nil
        continuation?.resume()
    }
}

extension AssistantSpeechSpeaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            self?.finishCurrentUtterance(matching: utteranceID)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            self?.finishCurrentUtterance(matching: utteranceID)
        }
    }
}
