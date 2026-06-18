import Foundation

public enum BrowserCredentialIntegrationKind: String, CaseIterable, Sendable {
    case chromePasswords
    case chromeCookies
    case chromeProfileReuse
    case chromeSyncPasswords
}

public enum BrowserCredentialIntegrationMatrix {
    public static func verdict(for kind: BrowserCredentialIntegrationKind) -> ChromeIntegrationVerdict {
        switch kind {
        case .chromePasswords:
            return ChromeIntegrationMatrix.verdict(for: .passwords, via: .directProfileDatabaseRead)
        case .chromeCookies:
            return ChromeIntegrationMatrix.verdict(for: .cookies, via: .directProfileDatabaseRead)
        case .chromeProfileReuse:
            return ChromeIntegrationMatrix.verdict(for: .bookmarks, via: .liveProfileReuseAsContinuumProfile)
        case .chromeSyncPasswords:
            return ChromeIntegrationMatrix.verdict(for: .passwords, via: .chromeSyncReuse)
        }
    }

    public static let `default`: [BrowserCredentialIntegrationKind: ChromeIntegrationVerdict] = Dictionary(
        uniqueKeysWithValues: BrowserCredentialIntegrationKind.allCases.map { ($0, verdict(for: $0)) }
    )
}
