import AppKit
import Foundation
import GhosttyKit

/// The pasteboards and the confirmation policy a terminal surface uses for
/// Ghostty's clipboard callbacks. Production terminals share `.system`; a check
/// injects private named pasteboards and a scripted `confirm`, so it never
/// touches the user's real clipboard or raises an alert.
///
/// Confirmation follows Ghostty's own semantics: Ghostty decides WHEN a read
/// needs confirming (an unsafe paste under `clipboard-paste-protection`, an
/// OSC 52 read under `clipboard-read = ask`, an OSC 52 write under
/// `clipboard-write = ask`) and calls back; this type only asks the user.
@MainActor
final class TerminalClipboard {
    enum Request: Equatable {
        case paste
        case osc52Read
        case osc52Write
    }

    typealias Confirm = @MainActor (
        _ text: String,
        _ request: Request,
        _ window: NSWindow?,
        _ decide: @escaping @MainActor (Bool) -> Void
    ) -> Void

    let standard: NSPasteboard
    let selection: NSPasteboard
    var confirm: Confirm

    init(standard: NSPasteboard, selection: NSPasteboard, confirm: @escaping Confirm) {
        self.standard = standard
        self.selection = selection
        self.confirm = confirm
    }

    static let system = TerminalClipboard(
        standard: .general,
        selection: NSPasteboard(name: NSPasteboard.Name("dev.arrayapp.terminal.selection")),
        confirm: TerminalClipboard.confirmWithAlert
    )

    func pasteboard(for location: ghostty_clipboard_e) -> NSPasteboard {
        location == GHOSTTY_CLIPBOARD_SELECTION ? selection : standard
    }

    /// Plain text if the pasteboard has it; otherwise copied files as their
    /// shell-escaped paths, which is what a terminal paste of a file means.
    func readString(from location: ghostty_clipboard_e) -> String? {
        let board = pasteboard(for: location)
        if let text = board.string(forType: .string) { return text }
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls.map { Self.shellEscaped($0.path) }.joined(separator: " ")
        }
        return nil
    }

    func write(_ text: String, to location: ghostty_clipboard_e) {
        let board = pasteboard(for: location)
        board.clearContents()
        board.setString(text, forType: .string)
    }

    private static func shellEscaped(_ path: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+-./:=,@%")
        if path.unicodeScalars.allSatisfy({ safe.contains($0) }) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func confirmWithAlert(
        text: String,
        request: Request,
        window: NSWindow?,
        decide: @escaping @MainActor (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch request {
        case .paste:
            alert.messageText = "Paste text that may run commands?"
            alert.informativeText = "The clipboard holds a line break or control characters, so pasting it into this terminal can run commands immediately."
            alert.addButton(withTitle: "Paste")
        case .osc52Read:
            alert.messageText = "Let this terminal program read your clipboard?"
            alert.informativeText = "A program running in the terminal asked for the clipboard's contents."
            alert.addButton(withTitle: "Allow")
        case .osc52Write:
            alert.messageText = "Let this terminal program replace your clipboard?"
            alert.informativeText = "A program running in the terminal asked to put text on the clipboard."
            alert.addButton(withTitle: "Allow")
        }
        alert.addButton(withTitle: "Cancel")
        let preview = text.count > 400 ? String(text.prefix(400)) + "…" : text
        let field = NSTextField(wrappingLabelWithString: preview)
        field.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        field.frame = NSRect(x: 0, y: 0, width: 360, height: min(160, max(20, field.fittingSize.height)))
        alert.accessoryView = field
        if let window {
            alert.beginSheetModal(for: window) { response in
                decide(response == .alertFirstButtonReturn)
            }
        } else {
            decide(alert.runModal() == .alertFirstButtonReturn)
        }
    }
}

/// Ghostty's C clipboard callbacks. `userdata` is the surface's userdata, the
/// unretained `GhosttyTerminalView`. Ghostty raises these on the app thread
/// (key handling and `ghostty_app_tick` both run on main), so the view is
/// reached synchronously; a stray off-main call is hopped to main.
enum GhosttyClipboardBridge {
    static func read(
        userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?
    ) -> Bool {
        guard let userdata, Thread.isMainThread else { return false }
        let viewAddress = UInt(bitPattern: userdata)
        let stateAddress = state.map { UInt(bitPattern: $0) }
        return MainActor.assumeIsolated {
            guard let pointer = UnsafeMutableRawPointer(bitPattern: viewAddress) else { return false }
            let view = Unmanaged<GhosttyTerminalView>.fromOpaque(pointer).takeUnretainedValue()
            return view.completeClipboardRead(
                location: location,
                state: stateAddress.flatMap { UnsafeMutableRawPointer(bitPattern: $0) }
            )
        }
    }

    static func confirmRead(
        userdata: UnsafeMutableRawPointer?,
        string: UnsafePointer<CChar>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        guard let userdata, Thread.isMainThread else { return }
        let text = string.map { String(cString: $0) } ?? ""
        let viewAddress = UInt(bitPattern: userdata)
        let stateAddress = state.map { UInt(bitPattern: $0) }
        MainActor.assumeIsolated {
            guard let pointer = UnsafeMutableRawPointer(bitPattern: viewAddress) else { return }
            let view = Unmanaged<GhosttyTerminalView>.fromOpaque(pointer).takeUnretainedValue()
            view.confirmClipboardRead(
                text: text,
                state: stateAddress.flatMap { UnsafeMutableRawPointer(bitPattern: $0) },
                request: request
            )
        }
    }

    static func write(
        userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        count: Int,
        confirm: Bool
    ) {
        guard let userdata, let content, count > 0 else { return }
        var text: String?
        for index in 0..<count {
            let item = content[index]
            guard let data = item.data else { continue }
            let mime = item.mime.map { String(cString: $0) } ?? "text/plain"
            if mime.hasPrefix("text/plain") || text == nil {
                text = String(cString: data)
            }
        }
        guard let text else { return }
        let address = UInt(bitPattern: userdata)
        let deliver: @MainActor () -> Void = {
            guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
            let view = Unmanaged<GhosttyTerminalView>.fromOpaque(pointer).takeUnretainedValue()
            view.writeClipboard(text, location: location, confirm: confirm)
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated { deliver() }
        } else {
            DispatchQueue.main.async { deliver() }
        }
    }
}
