import AppKit
import ContinuumRevivedCore
import Foundation

typealias BrowserRuntimeID = UUID

enum BrowserLoadingState: Equatable {
    case idle
    case loading(progress: Double)
    case failed(message: String)
}

@MainActor
protocol BrowserRuntime: AnyObject {
    var id: BrowserRuntimeID { get }
    var tileId: TileID { get }
    var url: String { get }
    var title: String { get }
    var loadingState: BrowserLoadingState { get }

    var onStateChange: (() -> Void)? { get set }

    func attach(to hostView: BrowserHostView)
    func detach()
    func loadURL(_ urlString: String)
    func goBack()
    func goForward()
    func reload()
    func stop()
    func focus()
    func blur()
    func isSemanticContentResponder(_ responder: NSResponder?) -> Bool
    func terminate(policy: TerminationPolicy)
}

final class BrowserHostView: NSView {
    private weak var runtime: BrowserRuntime?
    var reservedShortcutHandler: ((NSEvent) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func attach(runtime: BrowserRuntime) {
        self.runtime = runtime
        runtime.attach(to: self)
    }

    func detachRuntime() {
        runtime?.detach()
        runtime = nil
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if reservedShortcutHandler?(event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
