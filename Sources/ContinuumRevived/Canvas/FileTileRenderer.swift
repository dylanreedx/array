import AppKit

/// A file body owns presentation only. FileTileNSView retains document identity,
/// navigation, persistence and the one scene-residency lifecycle.
@MainActor
protocol FileTileRenderer: AnyObject {
    var view: NSView { get }
    var focusView: NSView { get }
    var revision: UInt64 { get }
    var scrollOffsets: [CGPoint] { get }
    var onRevisionChange: (() -> Void)? { get set }
    func applyTheme()
    func setVisible(_ visible: Bool)
    func dispose()
}
