import AppKit
import ContinuumRevivedCore
import Foundation

typealias TerminalSessionID = UUID
typealias TileID = UUID

enum TerminationPolicy: Equatable {
    case requestClose
    case force
}

@MainActor
protocol TerminalRuntime: AnyObject {
    var id: TerminalSessionID { get }
    var tileId: TileID { get }
    var title: String { get }
    var status: TerminalStatus { get }

    func attach(to hostView: TerminalHostView)
    func detach()
    func dehydrateForSnapshot()
    func rehydrateFromSnapshot()
    func focus()
    func blur()
    func resize(cols: Int, rows: Int, pixelSize: CGSize)
    func sendInput(_ bytes: Data)
    func terminate(policy: TerminationPolicy)
}

final class TerminalHostView: NSView {
    private weak var runtime: TerminalRuntime?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func applyTerminalBackground(_ color: NSColor?) {
        guard let color else { return }
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
    }

    func attach(runtime: TerminalRuntime) {
        self.runtime = runtime
        runtime.attach(to: self)
    }

    func detachRuntime() {
        runtime?.detach()
        runtime = nil
    }

    func dehydrateRuntimeForSnapshot() {
        runtime?.dehydrateForSnapshot()
    }

    func rehydrateRuntimeFromSnapshot() {
        runtime?.rehydrateFromSnapshot()
    }
}
