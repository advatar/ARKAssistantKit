/// Picks the most natural text-to-speech voice for the assistant and the pet.
///
/// Ported from BrIAn's Twin Pet voice work: an authorized Personal Voice wins,
/// then the voice the owner explicitly selected in System Settings → Accessibility
/// → Spoken Content (read via the legacy accessor, since AVFoundation has no
/// modern one and its locale default ignores the user's choice), then the highest
/// quality installed voice for the user's language.

import AVFoundation
import Foundation
#if os(macOS)
import AppKit
#endif

public enum AssistantVoiceSelection {
    /// A ranked description of one installed voice, kept as plain data so the
    /// scoring is unit-testable without AVFoundation state.
    public struct VoiceCandidate: Sendable, Equatable {
        public let identifier: String
        public let language: String
        public let quality: Int
        public let isAuthorizedPersonalVoice: Bool
        public let isSystemSelected: Bool

        public init(
            identifier: String,
            language: String,
            quality: Int,
            isAuthorizedPersonalVoice: Bool = false,
            isSystemSelected: Bool = false
        ) {
            self.identifier = identifier
            self.language = language
            self.quality = quality
            self.isAuthorizedPersonalVoice = isAuthorizedPersonalVoice
            self.isSystemSelected = isSystemSelected
        }
    }

    /// The voice the owner explicitly chose in System Settings → Accessibility
    /// → Spoken Content. AVFoundation has no modern accessor for it, so the
    /// legacy synthesizer's default voice is read; its raw value is a valid
    /// AVSpeechSynthesisVoice identifier on current macOS.
    @available(macOS, deprecated: 14.0, message: "wraps the deprecated NSSpeechSynthesizer accessor on purpose")
    public nonisolated static func systemSelectedVoiceIdentifier() -> String? {
        #if os(macOS)
        let identifier = NSSpeechSynthesizer.defaultVoice.rawValue
        return identifier.isEmpty ? nil : identifier
        #else
        return nil
        #endif
    }

    /// The user's authorized Personal Voice, if one exists.
    public nonisolated static func authorizedPersonalVoiceIdentifier(
        locale: Locale = .autoupdatingCurrent
    ) -> String? {
        guard #available(iOS 17.0, macOS 14.0, *),
              AVSpeechSynthesizer.personalVoiceAuthorizationStatus == .authorized else {
            return nil
        }
        let personalVoices = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.voiceTraits.contains(.isPersonalVoice)
        }
        let preferredLanguage = locale.identifier.replacingOccurrences(of: "_", with: "-")
        let languagePrefix = preferredLanguage.prefix(2)
        return personalVoices.first(where: { $0.language == preferredLanguage })?.identifier
            ?? personalVoices.first(where: { $0.language.hasPrefix(languagePrefix) })?.identifier
            ?? personalVoices.first?.identifier
    }

    /// Pure scoring: Personal Voice > system-selected voice > quality
    /// (premium > enhanced > compact), with the robotic eloquence/legacy voices
    /// penalized. Explicit owner choices are respected across locales; other
    /// voices must match the preferred language (exact beats prefix).
    public nonisolated static func selectPreferredVoiceIdentifier(
        candidates: [VoiceCandidate],
        preferredLanguage: String
    ) -> String? {
        let prefix = preferredLanguage.prefix(2)
        let scored: [(candidate: VoiceCandidate, score: Int)] = candidates.compactMap { candidate in
            var score = 0
            if candidate.language == preferredLanguage {
                score += 100
            } else if candidate.language.hasPrefix(prefix) {
                score += 50
            } else if candidate.isAuthorizedPersonalVoice || candidate.isSystemSelected {
                // An explicit owner choice is respected regardless of locale.
                score += 0
            } else {
                return nil
            }
            if candidate.isAuthorizedPersonalVoice { score += 1_000 }
            if candidate.isSystemSelected { score += 500 }
            score += candidate.quality * 10
            if candidate.identifier.contains(".eloquence.")
                || candidate.identifier.hasPrefix("com.apple.speech.synthesis.voice.") {
                score -= 40
            }
            return (candidate, score)
        }
        return scored.max { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            return lhs.candidate.identifier > rhs.candidate.identifier
        }?.candidate.identifier
    }

    /// The voice the speaker should use, or `nil` to let AVFoundation pick.
    public nonisolated static func preferredVoiceIdentifier(
        locale: Locale = .autoupdatingCurrent
    ) -> String? {
        let personalIdentifier = authorizedPersonalVoiceIdentifier(locale: locale)
        let systemIdentifier = systemSelectedVoiceIdentifier()
        let candidates = AVSpeechSynthesisVoice.speechVoices().map { voice in
            VoiceCandidate(
                identifier: voice.identifier,
                language: voice.language,
                quality: voice.quality.rawValue,
                isAuthorizedPersonalVoice: voice.identifier == personalIdentifier,
                isSystemSelected: voice.identifier == systemIdentifier
            )
        }
        return selectPreferredVoiceIdentifier(
            candidates: candidates,
            preferredLanguage: locale.identifier.replacingOccurrences(of: "_", with: "-")
        )
    }
}
