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
    private var smokeTestExitCode: Int32?

    func applicationDidFinishLaunching(_ notification: Notification) {
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

            // Activate after the runtime is wired up: NSApp.activate can fire
            // applicationDidBecomeActive synchronously, and the focus path needs
            // a non-nil ghostty to forward set_focus into the surface.
            NSApp.activate(ignoringOtherApps: true)

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
        // Free the surface before the app: ghostty_app_free walks the surface
        // registry during teardown and dereferences PAC-protected pointers; if a
        // surface is still alive at that point, deinit traps with EXC_BAD_ACCESS.
        runtime?.terminate(policy: .force)
        hostView?.detachRuntime()
        runtime = nil
        ghostty?.shutdown()
        ghostty = nil
        if let exitCode = smokeTestExitCode {
            Foundation.exit(exitCode)
        }
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
        // 1.0s — exercise the IME/text path (ghostty_surface_text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            runtime.sendInput(Data("echo ghostty-ok\n".utf8))
        }

        // 2.0s — exercise the key path: up-arrow recalls the previous command.
        // Without ghostty_surface_key, the PUA codepoint goes nowhere useful and
        // the shell does not recall the history entry.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            runtime.dispatchKeyDown(
                keyCode: 0x7E,
                characters: "\u{F700}",
                charactersIgnoringModifiers: "\u{F700}"
            )
        }

        // 2.4s — Enter to execute the recalled command.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            runtime.dispatchKeyDown(keyCode: 0x24, characters: "\r")
        }

        // 2.8s — fill scrollback with enough output to push earlier lines off
        // the visible viewport, so a scroll-up has something to reveal. Send
        // the command body via the text path then Enter via the key path
        // (mirrors how a user types a command and presses Return).
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
            runtime.sendInput(Data("seq 1 60".utf8))
            runtime.dispatchKeyDown(keyCode: 0x24, characters: "\r")
        }

        // 3.5s — window resize must still complete without crashing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            window.setContentSize(NSSize(width: 860, height: 540))
        }

        // 4.0s — capture pre-scroll viewport, scroll up via the C scroll API,
        // then assert the viewport content changed. Proves Ghostty's scroll
        // engine is actually being driven from our wrapper.
        var preScrollText = ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            preScrollText = runtime.visibleText()
            runtime.scrollDirectly(deltaY: 400)
        }

        // 5.0s — verify and close through the production close path.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            let visibleText = runtime.visibleText()
            let occurrences = visibleText.components(separatedBy: "ghostty-ok").count - 1
            let textPathOk = occurrences >= 1
            // The initial echo produces 3 occurrences (shell echoes typed input
            // before its prompt is ready, so the typed line shows twice plus the
            // echo output). A successful key path adds at least one more
            // occurrence from the recalled `echo ghostty-ok` execution. Without
            // ghostty_surface_key, the PUA up-arrow codepoint goes nowhere, the
            // recall does not happen, and we cap at 3.
            //
            // Note: by t=5.0 the smoke test has scrolled up, so the viewport
            // shows older content rather than the most-recent prompts. The
            // initial echo + recall lines should still appear in the scrolled
            // viewport (if scroll moved up enough), so we keep the >= 4 floor.
            let keyPathOk = occurrences >= 4
            let scrollOk = preScrollText != visibleText

            if textPathOk && keyPathOk && scrollOk {
                print("Ghostty smoke test passed (text + key + scroll, occurrences=\(occurrences))")
                if ProcessInfo.processInfo.environment["CONTINUUM_DUMP_VISIBLE"] == "1" {
                    fputs("--- pre-scroll visible text ---\n", stderr)
                    fputs(preScrollText, stderr)
                    fputs("\n--- post-scroll visible text ---\n", stderr)
                    fputs(visibleText, stderr)
                    fputs("\n--- end ---\n", stderr)
                }
                self.smokeTestExitCode = 0
            } else {
                fputs(
                    "Ghostty smoke test failed: textPathOk=\(textPathOk) keyPathOk=\(keyPathOk) scrollOk=\(scrollOk) occurrences=\(occurrences)\n",
                    stderr
                )
                fputs("--- pre-scroll ---\n", stderr)
                fputs(preScrollText, stderr)
                fputs("\n--- post-scroll ---\n", stderr)
                fputs(visibleText, stderr)
                self.smokeTestExitCode = 2
            }

            // Exercise the production close path: any crash on shutdown surfaces
            // here rather than being hidden behind the manual-teardown shortcut.
            window.performClose(nil)
        }
    }
}
