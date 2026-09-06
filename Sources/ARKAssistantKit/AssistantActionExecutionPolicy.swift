import Foundation

/// A conservative execution veto, not an interpreter admission/length gate.
/// The model still receives the whole sentence. Explicit alternatives, negation
/// and hypothetical wording require a fresh unambiguous request before an action.
enum AssistantActionExecutionPolicy {
    static func requiresClarification(for utterance: String) -> Bool {
        if utterance.contains(where: { "\"“”`".contains($0) }) { return true }
        let text = " " + AssistantActionCatalog.normalize(utterance) + " "
        let vetoes = [
            " not ", " never ", " don t ", " doesn t ", " didn t ", " won t ",
            " can t ", " haven t ", " hasn t ", " shouldn t ", " wouldn t ",
            " or ", " hypothetically ", " suppose ", " what would happen ",
            " what happens if ", " if i ", " if we "
        ]
        return vetoes.contains { text.contains($0) }
    }

    static func clarification(for action: AssistantAction) -> String {
        return "I haven't performed an action. If you want \(action.title), please ask directly for that one action and name the intended project if relevant."
    }
}
