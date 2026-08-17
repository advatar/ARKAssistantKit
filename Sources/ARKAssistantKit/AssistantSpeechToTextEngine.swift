/// Documents the assistant Speech To Text Engine source in ARKAssistantKit in the shared Swift packages.
///
/// Primary declarations include `AssistantSpeechToTextEngine`.

import AVFoundation
import Speech

/// Streams microphone audio and emits partial/final text.
/// Uses SpeechAnalyzer/SpeechTranscriber on iOS/macOS 26+ and SFSpeechRecognizer fallback on older OS versions.
public final class AssistantSpeechToTextEngine {
    enum STTError: LocalizedError {
        case speechRecognizerDenied
        case recognizerUnavailable
        case speechTranscriberUnavailable
        case failedToStart(String)

        var errorDescription: String? {
            switch self {
            case .speechRecognizerDenied:
                return "Speech recognition permission was denied."
            case .recognizerUnavailable:
                return "Speech recognizer is unavailable."
            case .speechTranscriberUnavailable:
                return "Speech transcription is not available on this device."
            case .failedToStart(let message):
                return "Failed to start speech transcription: \(message)"
            }
        }
    }

    private enum EngineMode {
        case none
        case legacy
        case modern
    }

    @available(iOS 26.0, macOS 26.0, *)
    private final class ModernState {
        var inputSequence: AsyncStream<AnalyzerInput>?
        var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
        var transcriber: SpeechTranscriber?
        var analyzer: SpeechAnalyzer?
        var analyzerFormat: AVAudioFormat?
        var resultTask: Task<Void, Never>?
    }

    private var mode: EngineMode = .none

    // MARK: - Legacy (macOS 14 / iOS < 26)
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    // MARK: - Modern (macOS 26 / iOS 26)
    private var modernState: AnyObject?
    private let converter = AssistantAudioBufferConverter()

    @MainActor
    func requestSpeechPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// Prepares Apple's on-device speech assets without opening the microphone.
    ///
    /// This is intentionally separate from `start`: live sessions should not
    /// block on the first speech turn while iOS/macOS installs a language
    /// asset. `SpeechAnalyzer`/`AssetInventory` remain the source of truth, so
    /// ARK never downloads speech models from its own servers.
    @available(iOS 26.0, macOS 26.0, *)
    @MainActor
    public static func prepareAppleSpeechAssets(
        preferredLocale: Locale = .current,
        onProgress: @escaping @MainActor (Progress?) -> Void = { _ in }
    ) async {
        guard SpeechTranscriber.isAvailable else { return }
        let supported = Array(await SpeechTranscriber.supportedLocales)
        guard !supported.isEmpty else { return }
        let locale = resolveLocale(preferred: preferredLocale, supported: supported)
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        do {
            try await ensureAppleSpeechModel(
                for: transcriber,
                locale: locale,
                onDownloadProgress: onProgress
            )
        } catch {
            // Preparation is opportunistic. The foreground start path retries
            // through the same Apple-managed asset request and reports errors
            // when speech is actually requested.
            onProgress(nil)
        }
    }

    @MainActor
    func start(
        preferredLocale: Locale = .current,
        onPartial: @escaping @MainActor (String) -> Void,
        onFinal: @escaping @MainActor (String) -> Void,
        onDownloadProgress: @escaping @MainActor (Progress?) -> Void
    ) async throws {
        onDownloadProgress(nil)

        if #available(iOS 26.0, macOS 26.0, *) {
            try await startModern(
                preferredLocale: preferredLocale,
                onPartial: onPartial,
                onFinal: onFinal,
                onDownloadProgress: onDownloadProgress
            )
            mode = .modern
            return
        }

        try startLegacy(preferredLocale: preferredLocale, onPartial: onPartial, onFinal: onFinal)
        mode = .legacy
    }

    func handleAudioBuffer(_ buffer: AVAudioPCMBuffer) throws {
        guard buffer.frameLength > 0 else { return }

        switch mode {
        case .none:
            return
        case .legacy:
            request?.append(buffer)
        case .modern:
            if #available(iOS 26.0, macOS 26.0, *) {
                guard let state = modernState as? ModernState,
                      let inputContinuation = state.inputContinuation,
                      let analyzerFormat = state.analyzerFormat else { return }
                let converted = try converter.convert(buffer, to: analyzerFormat)
                guard converted.frameLength > 0 else { return }
                inputContinuation.yield(AnalyzerInput(buffer: converted))
            }
        }
    }

    @MainActor
    func stop() async {
        switch mode {
        case .none:
            return
        case .legacy:
            stopLegacy()
        case .modern:
            if #available(iOS 26.0, macOS 26.0, *) {
                await stopModern()
            } else {
                stopLegacy()
            }
        }
        mode = .none
    }

    // MARK: - Legacy Engine

    @MainActor
    private func startLegacy(
        preferredLocale: Locale,
        onPartial: @escaping @MainActor (String) -> Void,
        onFinal: @escaping @MainActor (String) -> Void
    ) throws {
        let supported = Array(SFSpeechRecognizer.supportedLocales())
        let locale = Self.resolveLocale(preferred: preferredLocale, supported: supported)
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw STTError.recognizerUnavailable
        }
        guard recognizer.isAvailable else {
            throw STTError.recognizerUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(iOS 16.0, macOS 14.0, *) {
            request.addsPunctuation = true
        }
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = false
        }

        self.recognizer = recognizer
        self.request = request
        recognitionTask = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                let text = result.bestTranscription.formattedString
                Task { @MainActor in
                    if result.isFinal {
                        onFinal(text)
                    } else {
                        onPartial(text)
                    }
                }
            }
            if error != nil {
                Task { @MainActor [weak self] in
                    self?.stopLegacy()
                    self?.mode = .none
                }
            }
        }
    }

    @MainActor
    private func stopLegacy() {
        request?.endAudio()
        recognitionTask?.finish()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        recognizer = nil
    }

    // MARK: - Modern Engine

    @available(iOS 26.0, macOS 26.0, *)
    @MainActor
    private func startModern(
        preferredLocale: Locale,
        onPartial: @escaping @MainActor (String) -> Void,
        onFinal: @escaping @MainActor (String) -> Void,
        onDownloadProgress: @escaping @MainActor (Progress?) -> Void
    ) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw STTError.speechTranscriberUnavailable
        }

        let supported = Array(await SpeechTranscriber.supportedLocales)
        guard !supported.isEmpty else {
            throw STTError.failedToStart("No supported speech locales were reported by the system.")
        }
        let locale = Self.resolveLocale(preferred: preferredLocale, supported: supported)

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        let state = ModernState()
        state.transcriber = transcriber
        state.analyzer = SpeechAnalyzer(modules: [transcriber])
        modernState = state

        try await Self.ensureAppleSpeechModel(for: transcriber, locale: locale, onDownloadProgress: onDownloadProgress)
        state.analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        state.inputSequence = AsyncStream<AnalyzerInput> { continuation in
            state.inputContinuation = continuation
        }

        state.resultTask = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    await MainActor.run {
                        if result.isFinal {
                            onFinal(text)
                        } else {
                            onPartial(text)
                        }
                    }
                }
            } catch {
                if !Task.isCancelled {
                    print("[ARKAssistantKit] modern speech stream error: \(error)")
                }
            }
        }

        guard let inputSequence = state.inputSequence else {
            throw STTError.failedToStart("Could not create analyzer input stream.")
        }
        try await state.analyzer?.start(inputSequence: inputSequence)
    }

    @available(iOS 26.0, macOS 26.0, *)
    @MainActor
    private func stopModern() async {
        guard let state = modernState as? ModernState else {
            modernState = nil
            return
        }

        state.inputContinuation?.finish()
        do {
            try await state.analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            print("[ARKAssistantKit] modern speech finalize error: \(error)")
        }

        state.resultTask?.cancel()
        state.resultTask = nil
        state.analyzer = nil
        state.transcriber = nil
        state.analyzerFormat = nil
        state.inputSequence = nil
        state.inputContinuation = nil
        modernState = nil
    }

    @available(iOS 26.0, macOS 26.0, *)
    @MainActor
    private static func ensureAppleSpeechModel(
        for module: SpeechTranscriber,
        locale: Locale,
        onDownloadProgress: @escaping @MainActor (Progress?) -> Void
    ) async throws {
        let targetId = Self.normalizedLocaleIdentifier(locale)
        let installedLocales = await SpeechTranscriber.installedLocales
        let installedIds = Set(installedLocales.map(Self.normalizedLocaleIdentifier(_:)))
        if installedIds.contains(targetId) {
            onDownloadProgress(nil)
            return
        }

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            onDownloadProgress(request.progress)
            try await request.downloadAndInstall()
            onDownloadProgress(nil)
        }
    }

    // MARK: - Locale resolution

    private static func resolveLocale(preferred: Locale, supported: [Locale]) -> Locale {
        guard !supported.isEmpty else { return preferred }

        let normalizedPreferred = normalizedLocaleIdentifier(preferred)
        if let exact = supported.first(where: { normalizedLocaleIdentifier($0) == normalizedPreferred }) {
            return exact
        }

        let preferredLanguage = languageIdentifier(preferred)
        if preferredLanguage == "en" {
            let englishPriority = ["en-us", "en-gb", "en-au", "en-ca", "en-nz"]
            for localeId in englishPriority {
                if let match = supported.first(where: { normalizedLocaleIdentifier($0) == localeId }) {
                    return match
                }
            }
        }

        if let languageMatch = supported.first(where: { languageIdentifier($0) == preferredLanguage }) {
            return languageMatch
        }

        if let english = supported.first(where: { languageIdentifier($0) == "en" }) {
            return english
        }

        return supported[0]
    }

    private static func languageIdentifier(_ locale: Locale) -> String {
        if #available(iOS 16.0, macOS 14.0, *) {
            if let modern = locale.language.languageCode?.identifier.lowercased(),
               !modern.isEmpty {
                return modern
            }
        }
        let normalized = normalizedLocaleIdentifier(locale)
        return normalized.split(separator: "-").first.map { String($0) } ?? "en"
    }

    private static func normalizedLocaleIdentifier(_ locale: Locale) -> String {
        locale.identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }
}
