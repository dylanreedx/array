import Foundation

public enum ProjectLockPolicy: Sendable {
    public static func alertConfiguration(lockFile: URL) -> ProjectLockAlertConfiguration {
        ProjectLockAlertConfiguration(
            message: "This project is already open in another Array window.",
            informative: "Lock file: \(lockFile.path)\n\nOpen Anyway proceeds without the project lock and can risk conflicting writes. Choose Another Project is the safe default.",
            buttonTitles: ["Choose Another Project", "Open Anyway", "Quit"],
            defaultButtonIndex: 0,
            openAnywayIndex: 1,
            quitIndex: 2
        )
    }
}

public struct ProjectLockAlertConfiguration: Equatable, Sendable {
    public let message: String
    public let informative: String
    public let buttonTitles: [String]
    /// Zero-based index in the rendered alert button list.
    public let defaultButtonIndex: Int
    /// Zero-based index for the unsafe lock-bypass action.
    public let openAnywayIndex: Int
    /// Zero-based index for the terminate action.
    public let quitIndex: Int

    public init(
        message: String,
        informative: String,
        buttonTitles: [String],
        defaultButtonIndex: Int,
        openAnywayIndex: Int,
        quitIndex: Int
    ) {
        self.message = message
        self.informative = informative
        self.buttonTitles = buttonTitles
        self.defaultButtonIndex = defaultButtonIndex
        self.openAnywayIndex = openAnywayIndex
        self.quitIndex = quitIndex
    }
}
