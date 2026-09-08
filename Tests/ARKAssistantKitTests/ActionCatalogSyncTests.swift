import XCTest
@testable import ARKAssistantKit

/// Guards the boundary the shared catalog exists to hold.
///
/// The bundled catalog is a copy of the one in the `assistant` repository. These
/// tests fail when the copy drifts, and when an action claims more authority than
/// the model allows.
final class ActionCatalogSyncTests: XCTestCase {
    private var repositoryRoot: URL {
        // Tests/ARKAssistantKitTests -> Tests -> ARKAssistantKit -> Packages -> repo
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testBundledCatalogMatchesTheSharedCatalog() throws {
        let shared = repositoryRoot
            .appendingPathComponent("assistant/catalog/actions.json")
        guard let sharedData = try? Data(contentsOf: shared) else {
            throw XCTSkip("assistant submodule is not checked out")
        }
        let bundled = try XCTUnwrap(Bundle.module.url(forResource: "actions", withExtension: "json"))
        let bundledData = try Data(contentsOf: bundled)

        XCTAssertEqual(
            String(data: bundledData, encoding: .utf8),
            String(data: sharedData, encoding: .utf8),
            "Bundled catalog is stale. Run Packages/ARKAssistantKit/Scripts/sync-action-catalog.sh"
        )
    }

    func testCatalogDecodesAndIsNotEmpty() {
        XCTAssertFalse(ARKAssistantActions.catalog.actions.isEmpty)
    }

    func testNativeConversationCatalogExcludesUnimplementedAndInitiatingActions() {
        for surface in [AssistantAction.Surface.mac, .ios] {
            let conversation = ARKAssistantActions.conversationCatalog(for: surface)
            XCTAssertEqual(conversation.actions.count, 13)
            XCTAssertTrue(conversation.actions.allSatisfy { $0.isAvailable(on: surface) && $0.authority != .initiate })
            for name in ["app.install", "session.start", "attestation.request", "session.get", "people.resolve"] {
                XCTAssertNil(conversation.action(named: name))
            }
        }
        XCTAssertTrue(ARKAssistantActions.conversationCatalog(for: .mcp).actions.isEmpty)
    }

    func testActionNamesAreUnique() {
        let names = ARKAssistantActions.catalog.actions.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "Duplicate action names in the catalog")
    }

    func testNavigationIsNeverOfferedOnTheHostedSurface() {
        let leaked = ARKAssistantActions.catalog.actions
            .filter { $0.authority == .navigate && $0.isAvailable(on: .mcp) }
            .map(\.name)
        XCTAssertEqual(leaked, [], "Navigation needs a device in front of the user")
    }

    func testCeremonyCompletedActionsNeverExceedInitiate() {
        let overreaching = ARKAssistantActions.catalog.actions
            .filter { $0.completedByDeviceCeremony && $0.authority != .initiate }
            .map(\.name)
        XCTAssertEqual(overreaching, [], "A ceremony completes these; nothing may authorize them")
    }

    func testAgentSourcesAreDistinguishableFromPeople() {
        XCTAssertTrue(AssistantActionInvocation.Source.mcp.isAgent)
        XCTAssertTrue(AssistantActionInvocation.Source.mcpLocal.isAgent)
        XCTAssertTrue(AssistantActionInvocation.Source.computerUse.isAgent)
        XCTAssertFalse(AssistantActionInvocation.Source.voice.isAgent)
        XCTAssertFalse(AssistantActionInvocation.Source.siri.isAgent)
    }
}

/// The pet's liveness must stay presentation-only: distinct, deterministic poses
/// that never imply signal the app does not have.
final class AssistantPetPoseTests: XCTestCase {
    private func descriptor(_ phase: AssistantVoicePhase, muted: Bool = false) -> ARKPetStateDescriptor {
        ARKPetStateDescriptor(phase: phase, isMuted: muted, error: nil)
    }

    func testEveryStateHasThreeCapPositions() {
        for phase in [AssistantVoicePhase.ready, .listening, .thinking, .speaking, .unavailable] {
            XCTAssertEqual(descriptor(phase).faderPose.count, 3, "\(phase) needs a pose for each cap")
        }
        XCTAssertEqual(descriptor(.ready, muted: true).faderPose.count, 3)
    }

    func testPosesAreDeterministic() {
        XCTAssertEqual(descriptor(.listening).faderPose, descriptor(.listening).faderPose)
    }

    func testActiveStatesArePosedDistinctly() {
        let poses = [
            descriptor(.ready).faderPose,
            descriptor(.listening).faderPose,
            descriptor(.thinking).faderPose,
            descriptor(.speaking).faderPose,
        ]
        XCTAssertEqual(Set(poses.map(\.description)).count, poses.count, "States should be tellable apart")
    }

    func testMutedOverridesThePhasePose() {
        let muted = descriptor(.listening, muted: true).faderPose
        XCTAssertEqual(muted, descriptor(.ready, muted: true).faderPose)
        XCTAssertNotEqual(muted, descriptor(.listening).faderPose)
    }

    func testPosesStayWithinTheCharacterBounds() {
        for phase in [AssistantVoicePhase.ready, .listening, .thinking, .speaking, .unavailable] {
            for offset in descriptor(phase).faderPose {
                XCTAssertLessThanOrEqual(abs(offset), 12, "\(phase) pose would push a cap outside its fader")
            }
        }
    }
}
