import Foundation

public enum ChromeIntegrationDataKind: String, CaseIterable, Sendable {
    case bookmarks
    case history
    case cookies
    case passwords
    case extensions
    case tabs
    case chromeSync
    case cdpDefaultProfile
}

public enum ChromeIntegrationMethod: String, CaseIterable, Sendable {
    case directProfileDatabaseRead
    case liveProfileReuseAsContinuumProfile
    case chromeSyncReuse
    case companionExtensionNativeMessaging
    case userChosenExportImportFile
    case cdpAttachDefaultUserProfile
    case isolatedChromeCDPAppOwnedUserDataDir
    case externalBrowserHandoff
}

public enum ChromeIntegrationVerdict: Equatable, Sendable {
    case rejected(reason: String)
    case conditionallySafe(requirement: String)
    case outOfScope(reason: String)
    case unavailable(reason: String)

    public var isRejected: Bool {
        if case .rejected = self { return true }
        return false
    }
}

public enum ChromeIntegrationMatrix {
    public static func verdict(
        for dataKind: ChromeIntegrationDataKind,
        via method: ChromeIntegrationMethod
    ) -> ChromeIntegrationVerdict {
        switch method {
        case .directProfileDatabaseRead:
            return .rejected(reason: "Continuum must not read Chrome profile databases or secret stores directly.")
        case .liveProfileReuseAsContinuumProfile:
            return .rejected(reason: "Continuum WKWebView profiles must be app-owned; never reuse the user's live Chrome profile.")
        case .chromeSyncReuse:
            return .unavailable(reason: "Chrome Sync is not an available third-party app integration path and must not be treated as supported.")
        case .cdpAttachDefaultUserProfile:
            return .rejected(reason: "CDP attachment to the user's default Chrome profile is not allowed.")
        case .externalBrowserHandoff:
            return .outOfScope(reason: "External-browser handoff is user-deferred and out of scope for this bundle.")
        case .companionExtensionNativeMessaging:
            switch dataKind {
            case .tabs:
                return .conditionallySafe(requirement: "Requires explicit user action, declared extension permissions, extension ID allowlist, and constrained message schema.")
            default:
                return .outOfScope(reason: "Extension/native messaging is a later design spike, not automatic sync.")
            }
        case .userChosenExportImportFile:
            switch dataKind {
            case .bookmarks, .history:
                return .conditionallySafe(requirement: "Only user-mediated import/export from a user-chosen file is allowed.")
            default:
                return .rejected(reason: "User file import must not import Chrome cookies, passwords, sessions, extensions, or sync secrets.")
            }
        case .isolatedChromeCDPAppOwnedUserDataDir:
            switch dataKind {
            case .cdpDefaultProfile:
                return .conditionallySafe(requirement: "Developer automation may use only an isolated app-owned --user-data-dir, never the default user profile.")
            default:
                return .outOfScope(reason: "Isolated Chrome/CDP is limited to later developer automation, not profile sync.")
            }
        }
    }
}
