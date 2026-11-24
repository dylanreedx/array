import AppKit
import SwiftUI
import UserNotifications

/// Whether macOS lets Array post banners (MAC-01, MAC-02). Read live: a change
/// in System Settings reaches the running app with no relaunch.
enum MacNotificationAuthorization: Equatable {
    case allowed
    case denied
    case notDetermined
    /// Not a real app bundle (checks, bare binaries): the center would trap.
    case unavailable

    /// The Settings row shows only while banners cannot reach the user.
    var needsAttention: Bool { self == .denied || self == .notDetermined }
}

@MainActor
enum MacNotificationPermission {
    /// Checks swap these so no check reads the real center or opens a window.
    static var qaStatus: (() -> MacNotificationAuthorization)?
    static var qaOpenURL: ((URL) -> Void)?
    static var qaRequest: (() -> Void)?

    /// System Settings › Notifications › Array.
    static var settingsURL: URL {
        let id = Bundle.main.bundleIdentifier ?? "dev.arrayapp.macos"
        return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")!
    }

    private static var isRealBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    static func read(_ done: @escaping @MainActor (MacNotificationAuthorization) -> Void) {
        if let qaStatus { done(qaStatus()); return }
        guard isRealBundle else { done(.unavailable); return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status: MacNotificationAuthorization
            switch settings.authorizationStatus {
            case .notDetermined: status = .notDetermined
            case .denied: status = .denied
            default: status = .allowed
            }
            Task { @MainActor in done(status) }
        }
    }

    static func openSettings() {
        if let qaOpenURL { qaOpenURL(settingsURL); return }
        NSWorkspace.shared.open(settingsURL)
    }

    /// Only from the user's own click: macOS lists Array under Notifications
    /// only after it has asked once, so "not set up" asks instead of deep-linking
    /// to a pane with no Array in it.
    static func request(_ done: @escaping @MainActor () -> Void) {
        if let qaRequest { qaRequest(); done(); return }
        guard isRealBundle else { done(); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            Task { @MainActor in done() }
        }
    }
}

/// One calm row at the top of Notifications & Sounds while banners are off.
struct SettingsNotificationPermissionSection: View {
    let model: SettingsModel

    static let textID = "macNotifications.status"

    var body: some View {
        let status = model.macNotifications
        if status.needsAttention {
            let denied = status == .denied
            let detail = denied
                ? "Array can’t show a banner when an agent needs you while you’re in another app."
                : "Array shows a banner when an agent needs you while you’re in another app."
            Section {
                StatusRow(title: "Notifications", status: denied ? "Off" : "Not set up", symbol: "bell.slash",
                          tone: .neutral, detail: detail,
                          actionTitle: denied ? "Open Notification Settings" : "Allow Notifications…",
                          action: { denied ? model.openNotificationSettings() : model.requestNotifications() })
                    .settingsRenderedText(Self.textID, denied ? "denied" : "notDetermined", model: model)
            } header: {
                Text("Mac alerts")
            }
        }
    }
}
