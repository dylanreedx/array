import AppKit
import ContinuumRevivedCore

/// Both agent entry points use the shared choice surface and this palette.
@MainActor
enum AgentIdentityColourPicker {
    static var items: [ChoiceItem] {
        [ChoiceItem(id: "none", title: "None", icon: .system("circle.slash"))]
            + ZoneColorConfig.palette.map { name in
                var item = ChoiceItem(id: name, title: name.capitalized)
                item.swatch = ZoneChromeNSView.color(named: name)
                return item
            }
    }
}

final class AgentIdentityColourMenuItem: NSMenuItem {
    var choice: ChoiceItem?
}
