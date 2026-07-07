import Foundation

public enum CompanionSyncConfig {
    /// Dogfood CloudKit transport container shared by the signed macOS publisher
    /// and the installed iOS companion. This is transport configuration only:
    /// pairing/authorization still comes from Continuum instance auth.
    public static let cloudKitContainerIdentifier = "iCloud.dev.dylanreedx.continuum"
}
