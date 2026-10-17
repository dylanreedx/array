import ActivityKit
import WidgetKit
import SwiftUI

struct AgentActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var working: Int
        var needsYou: Int
    }
    var workspace: String
}
