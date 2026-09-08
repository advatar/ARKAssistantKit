import Foundation

/// Shared vocabulary for the Mac pet and mobile chat. Hosts enforce platform capabilities.
public enum ARKAssistantActions {
    public static let catalog = AssistantActionCatalog(actions: [
        action("protection.listProjects", "List Projects", "Lists the signed-in user's available ARK projects.",
               ["list projects", "list my projects", "which projects do i have", "what projects do i have", "show my projects"]),
        action("protection.projectStatus", "Project Status", "Reports the selected project's recorded state.",
               ["project status", "current project status", "how is the project", "what is the project status"], project: true),
        action("requests.pending", "Pending Requests", "Reports pending invitations, without accepting or signing anything.",
               ["what's pending", "what is pending", "pending requests", "what needs attention"]),
        action("navigation.work", "Show Work", "Opens the existing work or projects view.",
               ["show work", "show dashboard", "show the dashboard", "open work"]),
        action("navigation.requests", "Show Requests", "Selects the existing requests view.",
               ["show requests", "show my requests", "show shares", "open requests"]),
        action("navigation.evidence", "Show Evidence", "Selects the existing proofs view; does not generate or sign a proof.",
               ["show evidence", "show my evidence", "show proofs", "open proofs"]),
        action("navigation.help", "Show Help", "Selects the existing help view.",
               ["show help", "open help", "i need help"]),
        action("navigation.project", "Open Project", "Opens a managed project's existing view.",
               ["open project", "show current project"], project: true),
        action("navigation.liveSession", "Open Live Session", "Opens the Live Session panel. Does not start a session or recording.",
               ["open live session", "show live session"], project: true),
        action("navigation.eventHistory", "Open Event History", "Opens the project's recorded event history.",
               ["show event history", "open event history"], project: true),
        action("assistant.openChat", "Open Chat", "Opens the existing assistant chat with this same conversation.",
               ["open chat", "show chat", "open assistant chat"]),
        action("assistant.openPet", "Open Session Assistant", "Opens the Session Assistant without starting microphone capture.",
               ["open pet", "show pet", "open session assistant", "show session assistant"]),
        action("assistant.muteMicrophone", "Mute Microphone", "Cancels capture and mutes the pet microphone.",
               ["mute the mic", "mute microphone", "mute the microphone", "stop listening"])
    ])

    private static func action(_ name: String, _ title: String, _ description: String,
                               _ phrases: [String], project: Bool = false) -> AssistantAction {
        AssistantAction(name: name, title: title, description: description,
                        category: .assistant, phrases: phrases, parameters: project
                            ? [.init(name: "project", title: "Exact project name or ID; omit to use the selected project")]
                            : [])
    }
}
