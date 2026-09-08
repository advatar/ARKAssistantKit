import Foundation

/// Shared vocabulary for the Mac pet and mobile chat. Hosts enforce platform capabilities.
///
/// The actions are not written here. They are decoded from `Resources/actions.json`,
/// which mirrors the shared catalog in the `assistant` repository, so the Mac app,
/// the iOS app, Siri and the MCP surfaces all describe the same actions with the
/// same authority levels. Run `Scripts/sync-action-catalog.sh` after changing the
/// catalog; `ActionCatalogSyncTests` fails if the copy drifts.
public enum ARKAssistantActions {
    public static let catalog = AssistantActionCatalog(actions: decodedActions())

    /// Actions a given host is allowed to offer.
    public static func actions(for surface: AssistantAction.Surface) -> [AssistantAction] {
        catalog.actions.filter { $0.isAvailable(on: surface) }
    }

    /// Current native conversation handlers implement navigation and these reads,
    /// not every operation exposed by the shared server catalog.
    public static func conversationCatalog(for surface: AssistantAction.Surface) -> AssistantActionCatalog {
        guard surface == .mac || surface == .ios else { return .init(actions: []) }
        let supported: Set<String> = [
            "protection.listProjects", "protection.projectStatus", "requests.pending",
            "navigation.work", "navigation.requests", "navigation.evidence", "navigation.help",
            "navigation.project", "navigation.liveSession", "navigation.eventHistory",
            "assistant.openChat", "assistant.openPet", "assistant.muteMicrophone"
        ]
        return .init(actions: actions(for: surface).filter {
            supported.contains($0.name) && ($0.authority == .read || $0.authority == .navigate)
        })
    }

    struct CatalogDocument: Decodable {
        let version: Int
        let actions: [AssistantAction]
    }

    /// The decoded catalog, or a trap: a missing or malformed catalog is a build
    /// packaging fault, not a runtime condition worth degrading into a silently
    /// empty action list that would make every command quietly unavailable.
    static func decodedActions() -> [AssistantAction] {
        guard let url = Bundle.module.url(forResource: "actions", withExtension: "json") else {
            preconditionFailure("actions.json is missing from the ARKAssistantKit bundle")
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(CatalogDocument.self, from: data).actions
        } catch {
            preconditionFailure("actions.json could not be decoded: \(error)")
        }
    }
}
