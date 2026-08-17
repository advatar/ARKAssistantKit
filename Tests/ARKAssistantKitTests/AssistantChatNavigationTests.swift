/// Exercises assistant navigation link formatting in ARKAssistantKit.

import Testing
@testable import ARKAssistantKit

/// Verifies assistant chat messages can point users at app destinations.
struct AssistantChatNavigationTests {
    @Test func formatsSettingsNavigationLink() {
        #expect(
            AssistantChatViewModel.navigationLinkResponse(for: "open settings")
                == "Open [Settings](ark://navigate/settings)."
        )
    }

    @Test func ignoresPlainConversationWithoutNavigationIntent() {
        #expect(AssistantChatViewModel.navigationLinkResponse(for: "what can you do?") == nil)
    }
}
