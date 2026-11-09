import AppKit

/// Keep the retired flag recognized: removing it would boot the full app for
/// anyone following an old command. The one approved experiment is complete.
@MainActor
func runBrowserPointerRealActiveCheck() throws {
    throw WorkspaceAPIChecks.Failure(message: "REFUSED: active pointer experiment is retired; no activation occurred")
}
