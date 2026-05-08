import AppKit
import ContinuumRevivedCore
import Foundation
import GhosttyKit

@main
enum ContinuumApp {
    @MainActor
    private static var delegate: AppDelegate?

    @MainActor
    static func main() {
        let executablePath = CommandLine.arguments.first ?? "continuum-revived"
        let ghosttyInitStatus = executablePath.withCString { executablePointer in
            var argv: [UnsafeMutablePointer<CChar>?] = [
                UnsafeMutablePointer(mutating: executablePointer),
                nil
            ]
            return argv.withUnsafeMutableBufferPointer { buffer in
                ghostty_init(1, buffer.baseAddress)
            }
        }

        guard ghosttyInitStatus == GHOSTTY_SUCCESS else {
            fputs("ghostty_init failed\n", stderr)
            Foundation.exit(1)
        }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate

        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var ghostty: GhosttyRuntimeContext?
    private var runtime: GhosttyTerminalRuntime?
    private var hostView: TerminalHostView?
    private let smokeTestEnabled = ProcessInfo.processInfo.environment["CONTINUUM_SMOKE_TEST"] == "1"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)

        do {
            let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).path
            let launchProfile = try ShellLaunchResolver().resolveShell(cwd: repoRoot)
            let ghostty = try GhosttyRuntimeContext()
            let runtime = GhosttyTerminalRuntime(
                title: launchProfile.title,
                launchProfile: launchProfile,
                ghostty: ghostty
            )

            let hostView = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
            hostView.attach(runtime: runtime)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "continuum-revived Phase 1 Ghostty Spike"
            window.center()
            window.contentView = hostView
            window.delegate = self
            window.makeKeyAndOrderFront(nil)

            self.ghostty = ghostty
            self.runtime = runtime
            self.hostView = hostView
            self.window = window

            if smokeTestEnabled {
                runSmokeTest(window: window, runtime: runtime)
            }
        } catch {
            presentFatalError(error)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if let app = try? ghostty?.app {
            ghostty_app_set_focus(app, true)
        }
        runtime?.focus()
    }

    func applicationDidResignActive(_ notification: Notification) {
        if let app = try? ghostty?.app {
            ghostty_app_set_focus(app, false)
        }
        runtime?.blur()
    }

    func windowWillClose(_ notification: Notification) {
        runtime?.terminate(policy: .requestClose)
        hostView?.detachRuntime()
        runtime = nil
        ghostty?.shutdown()
        ghostty = nil
        NSApp.terminate(nil)
    }

    private func presentFatalError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Terminal engine failed to initialize."
        alert.informativeText = String(describing: error)
        alert.alertStyle = .critical
        alert.runModal()
        NSApp.terminate(nil)
    }

    private func runSmokeTest(window: NSWindow, runtime: GhosttyTerminalRuntime) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            runtime.sendInput(Data("echo ghostty-ok\n".utf8))
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            window.setContentSize(NSSize(width: 860, height: 540))
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            let visibleText = runtime.visibleText()
            let passed = visibleText.contains("ghostty-ok")
            runtime.terminate(policy: .requestClose)
            self.hostView?.detachRuntime()
            self.ghostty?.shutdown()

            if passed {
                print("Ghostty smoke test passed")
                Foundation.exit(0)
            } else {
                fputs("Ghostty smoke test failed: visible text did not contain ghostty-ok\n", stderr)
                fputs(visibleText, stderr)
                Foundation.exit(2)
            }
        }
    }
}
