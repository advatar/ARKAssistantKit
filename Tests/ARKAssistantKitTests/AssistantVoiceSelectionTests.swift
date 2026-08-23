import Testing
@testable import ARKAssistantKit

/// Mirrors BrIAn's Twin Pet voice-selection contract.
struct AssistantVoiceSelectionTests {
    private typealias Candidate = AssistantVoiceSelection.VoiceCandidate

    @Test func systemSelectedVoiceBeatsPremiumQuality() {
        let daniel = Candidate(
            identifier: "com.apple.voice.compact.en-GB.Daniel",
            language: "en-GB", quality: 1, isSystemSelected: true
        )
        let premium = Candidate(
            identifier: "com.apple.voice.premium.en-US.Zoe",
            language: "en-US", quality: 3
        )
        // Locale en_SE: Daniel is cross-locale but explicitly chosen.
        let chosen = AssistantVoiceSelection.selectPreferredVoiceIdentifier(
            candidates: [daniel, premium],
            preferredLanguage: "en-SE"
        )
        #expect(chosen == daniel.identifier)
    }

    @Test func personalVoiceBeatsSystemSelection() {
        let personal = Candidate(
            identifier: "personal.voice.me",
            language: "en-US", quality: 1, isAuthorizedPersonalVoice: true
        )
        let daniel = Candidate(
            identifier: "com.apple.voice.compact.en-GB.Daniel",
            language: "en-GB", quality: 1, isSystemSelected: true
        )
        let chosen = AssistantVoiceSelection.selectPreferredVoiceIdentifier(
            candidates: [daniel, personal],
            preferredLanguage: "en-US"
        )
        #expect(chosen == personal.identifier)
    }

    @Test func qualityRankingAppliesWhenNothingIsExplicitlyChosen() {
        let compact = Candidate(identifier: "compact.en-US", language: "en-US", quality: 1)
        let enhanced = Candidate(identifier: "enhanced.en-US", language: "en-US", quality: 2)
        let eloquence = Candidate(identifier: "voice.eloquence.en-US.Eddy", language: "en-US", quality: 3)
        let chosen = AssistantVoiceSelection.selectPreferredVoiceIdentifier(
            candidates: [compact, eloquence, enhanced],
            preferredLanguage: "en-US"
        )
        #expect(chosen == enhanced.identifier)
    }

    @Test func unrelatedLocalesAreExcludedUnlessExplicitlyChosen() {
        let swedish = Candidate(identifier: "compact.sv-SE", language: "sv-SE", quality: 3)
        let chosen = AssistantVoiceSelection.selectPreferredVoiceIdentifier(
            candidates: [swedish],
            preferredLanguage: "en-US"
        )
        #expect(chosen == nil)
    }
}
