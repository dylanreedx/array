import ContinuumRevivedCore
import Foundation
import WebKit

struct BrowserInspectionPolicy {
    static let userDefaultsKey = BrowserWebInspectorConfig.userDefaultsKey
    static let environmentKey = "CONTINUUM_BROWSER_WEB_INSPECTOR"

    let isEnabled: Bool
    let source: String

    static func resolved(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> BrowserInspectionPolicy {
        if let value = environment[environmentKey] {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["1", "true", "yes", "on"].contains(normalized) {
                return BrowserInspectionPolicy(isEnabled: true, source: "env")
            }
            if ["0", "false", "no", "off"].contains(normalized) {
                return BrowserInspectionPolicy(isEnabled: false, source: "env")
            }
        }
        if defaults.object(forKey: userDefaultsKey) == nil {
            return BrowserInspectionPolicy(isEnabled: BrowserWebInspectorConfig.defaultEnabled, source: "default")
        }
        return BrowserInspectionPolicy(isEnabled: defaults.bool(forKey: userDefaultsKey), source: "defaults")
    }

    @MainActor
    func apply(to webView: WKWebView) {
        if #available(macOS 13.3, *) {
            webView.isInspectable = isEnabled
        }
    }
}
