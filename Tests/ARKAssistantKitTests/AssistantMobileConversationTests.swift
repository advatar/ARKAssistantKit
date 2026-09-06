import Foundation
import Testing
@testable import ARKAssistantKit

@MainActor
private final class MobileConversationExecutor: AssistantActionExecutor {
    var calls: [String] = []
    func perform(_ invocation: AssistantActionInvocation) async -> AssistantActionOutcome {
        calls.append(invocation.action.name)
        return .init(message: "Projects\nOne project is available.",
                     a2uiSurfaceJSON: A2UISurface(surfaceID: "test", root: "root", components: [
                        .init(id: "root", component: .text, text: .path("/answer"))
                     ], dataModel: .object(["answer": .string("One project")])).encodeJSON())
    }
}

@MainActor
struct AssistantMobileConversationTests {
    @Test func mobileAndPetUseOneCatalogAndActionCardsStayWithTheirMessages() async {
        let executor = MobileConversationExecutor()
        let model = AssistantChatViewModel(actionCatalog: ARKAssistantActions.catalog,
                                           actionExecutor: executor, remoteToolsEnabled: false)
        model.inputText = "list my projects"
        model.sendCurrentInput()
        await model.responseTask?.value
        model.inputText = "what needs attention"
        model.sendCurrentInput()
        await model.responseTask?.value
        #expect(executor.calls == ["protection.listProjects", "requests.pending"])
        #expect(model.messages.filter { $0.visual != nil }.count == 2)
        #expect(model.messages.last?.visual == model.responseVisual)
        #expect(!model.isRecording)
        model.cancelInteraction(clearConversation: true)
        #expect(model.messages.isEmpty)
        #expect(model.responseVisual == nil)
    }

    @Test func naturalConversationRetainsContextAndComposesNativeVisuals() async {
        let executor = MobileConversationExecutor()
        let model = AssistantChatViewModel(contextSummary: "This host is iOS, not the Mac.",
            actionCatalog: ARKAssistantActions.catalog, actionExecutor: executor, remoteToolsEnabled: false)
        var prompts: [String] = []
        model.modelResponseOverride = { prompt, _ in
            prompts.append(prompt)
            return .init(text: "Here are the steps:\n1. Join the session.\n2. Review your contributions.",
                         providerLabel: "Deterministic test", permitsActionExecution: false)
        }
        model.inputText = "How should I get started with my band?"
        model.sendCurrentInput()
        await model.responseTask?.value
        model.inputText = "Could you explain the second step?"
        model.sendCurrentInput()
        await model.responseTask?.value
        #expect(prompts.count == 2)
        #expect(prompts.last?.contains("How should I get started with my band?") == true)
        #expect(prompts.last?.contains("This host is iOS") == true)
        #expect(model.messages.filter { $0.visual != nil }.count == 2)
        #expect(executor.calls.isEmpty)
    }

    @Test func visualActionsAreSingleFlightAndUnknownNamesCannotExecute() async {
        let executor = MobileConversationExecutor()
        let model = AssistantChatViewModel(actionCatalog: ARKAssistantActions.catalog,
            actionExecutor: executor, remoteToolsEnabled: false)
        model.submitAction(named: "sign.everything")
        #expect(model.messages.isEmpty)
        model.submitAction(named: "navigation.work")
        model.submitAction(named: "navigation.requests")
        await model.responseTask?.value
        #expect(executor.calls == ["navigation.work"])
    }

    @Test func disabledRemoteDiscoveryNeverConnectsEvenOnRefreshOrInventoryQuestion() async {
        let model = AssistantChatViewModel(actionCatalog: ARKAssistantActions.catalog, remoteToolsEnabled: false)
        await model.refreshTools()
        #expect(model.statusText == "App actions: available on this device")
        #expect(model.lastError == nil)
    }
}
