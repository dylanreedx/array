import Foundation

/// User-facing developer preference for making embedded browser tiles visible to
/// Safari Web Inspector. The app still must apply this through WebKit's
/// `WKWebView.isInspectable` availability-gated API; keeping the key in Core lets
/// the generic Settings schema expose the same preference the browser runtime
/// resolves.
public enum BrowserWebInspectorConfig {
    public static let userDefaultsKey = "continuum.browser.webInspectorEnabled"
    public static let defaultEnabled = false
}
