import AppKit

/// The header chip browser and simulator tiles share: who is driving the tile
/// and the user's control actions. One definition, so the same idea looks the
/// same on every tile that an agent can drive.
@MainActor
enum AgentControlChip {
    static func make(toolTip: String) -> ChoiceButton {
        let button = ChoiceButton(title: "Agent")
        button.isHidden = true
        button.popoverPresentation = .commands
        button.keepsSelectionForItem = { _ in true }
        button.toolTip = toolTip
        return button
    }
    static func title(agentName: String, engaged: Bool, userDriving: Bool) -> String? {
        userDriving ? "You’re driving" : (engaged ? "Driven by \(agentName)" : nil)
    }
    static let takeControl = ChoiceItem(id: "take", title: "Take control")
    static let allowAgentControl = ChoiceItem(id: "allow-agent", title: "Allow Agent Control")
}
