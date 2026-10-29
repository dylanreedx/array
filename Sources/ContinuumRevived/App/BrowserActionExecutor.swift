import ContinuumRevivedCore
import Foundation

/// Converts validated browser actions into engine calls and bounded replies.
/// The service must authorize, serialize and enforce navigation policy before
/// invoking this. This adapter is not registered as a tool on its own.
@MainActor
enum BrowserActionExecutor {
    static func perform(_ request: BrowserToolRequest, runtime: WKWebViewBrowserRuntime, deadline: Date,
                        checkoutRoot: URL? = nil) async -> WorkspaceAPIService.Reply {
        guard !runtime.isTerminated else {
            return .error(WorkspaceAPIError(code: .browserNotLive, message: "This browser is not live. Reload the tile."))
        }
        let engine = runtime.automation
        func reply(_ fields: [String: Any]) -> WorkspaceAPIService.Reply {
            .result(fields.mapValues { AnyHashableJSON(any: $0) })
        }
        func outcome(_ value: BrowserAutomationOutcome) -> WorkspaceAPIService.Reply {
            var fields: [String: Any] = ["summary": value.summary, "url": value.url, "title": value.title,
                                          "generation": engine.generation, "dialogs": value.dialogs,
                                          "consoleErrors": value.consoleErrors]
            if let changes = value.changes { fields["changes"] = changes }
            if let typed = value.value { fields["value"] = typed }
            return reply(fields)
        }
        do {
            switch request {
            case let .snapshot(tile, _) where tile == runtime.tileId:
                let value = try await engine.snapshot(deadline: deadline)
                return reply(["text": value.text, "generation": value.generation, "url": value.url,
                              "title": value.title, "cut": value.cut])
            case let .click(tile, target, _) where tile == runtime.tileId:
                switch target {
                case .ref(let ref): return outcome(try await engine.click(ref: ref, deadline: deadline))
                case .point(let x, let y): return outcome(try await engine.click(x: x, y: y, deadline: deadline))
                }
            case let .type(tile, text, ref, clear, submit, _) where tile == runtime.tileId:
                return outcome(try await engine.type(text, ref: ref, clear: clear, submit: submit, deadline: deadline))
            case let .pressKey(tile, name, _) where tile == runtime.tileId:
                return outcome(try await engine.pressKey(name, deadline: deadline))
            case let .scroll(tile, ref, dx, dy, _) where tile == runtime.tileId:
                return outcome(try await engine.scroll(ref: ref, dx: dx, dy: dy, deadline: deadline))
            case let .waitFor(tile, condition, timeout, _) where tile == runtime.tileId:
                let engineCondition: BrowserAutomation.WaitCondition
                switch condition {
                case .textAppears(let value): engineCondition = .textAppears(value)
                case .textGone(let value): engineCondition = .textGone(value)
                case .refAppears(let value): engineCondition = .refAppears(value)
                case .refGone(let value): engineCondition = .refGone(value)
                case .idle: engineCondition = .idle
                }
                return outcome(try await engine.waitFor(engineCondition, timeout: timeout, deadline: deadline))
            case let .screenshot(tile, ref, _) where tile == runtime.tileId:
                let image = try await engine.screenshot(ref: ref, deadline: deadline)
                return reply(["image": ["mimeType": "image/png", "data": image.png.base64EncodedString()],
                              "width": image.pixelWidth, "height": image.pixelHeight, "generation": engine.generation])
            case let .evaluate(tile, script, _) where tile == runtime.tileId:
                let json = try await engine.evaluate(script, deadline: deadline)
                let value = try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
                return reply(["value": value, "generation": engine.generation])
            case let .console(tile, level, _) where tile == runtime.tileId:
                let entries = runtime.consoleLogEntries.filter { level == nil || $0.level.rawValue == level }
                var rows: [[String: Any]] = []
                var cut = false
                for entry in entries.reversed() {
                    if entry.message.count > 512 || (entry.url?.count ?? 0) > 512 { cut = true }
                    let row: [String: Any] = ["level": entry.level.rawValue, "message": String(entry.message.prefix(512)),
                                              "url": String((entry.url ?? "").prefix(512)), "timestamp": entry.timestamp.timeIntervalSince1970]
                    let candidate = [row] + rows
                    if (try? JSONSerialization.data(withJSONObject: candidate).count) ?? Int.max > 20_000 { cut = true; break }
                    rows = candidate
                }
                return reply(["entries": rows, "pageSupplied": true, "truncated": cut, "generation": engine.generation])
            case let .navigate(tile, destination, _) where tile == runtime.tileId:
                guard let checkoutRoot, runtime.agentNavigationDecision != nil else {
                    return .error(WorkspaceAPIError(code: .permissionDenied, message: "Browser navigation policy is unavailable."))
                }
                switch await runtime.navigateForAgent(destination, checkoutRoot: checkoutRoot, deadline: deadline) {
                case .completed:
                    return outcome(try await engine.waitFor(.idle, timeout: max(0, deadline.timeIntervalSinceNow), deadline: deadline))
                case .denied:
                    return .error(WorkspaceAPIError(code: .scopeApprovalRequired, message: "The user did not approve that browser destination."))
                case .notLive:
                    return .error(WorkspaceAPIError(code: .browserNotLive, message: "The browser stopped while navigating. Reload the tile."))
                case .unavailable:
                    return .error(WorkspaceAPIError(code: .invalidRequest, message: "That navigation is unavailable. Check the browser history."))
                case .failed(let message):
                    return .error(WorkspaceAPIError(code: .outcomeUnknown, message: "Navigation did not complete: \(String(message.prefix(1024))). Take a fresh snapshot before retrying."))
                }
            default:
                return .error(WorkspaceAPIError(code: .invalidRequest, message: "The browser action does not match this tile."))
            }
        } catch let error as BrowserAutomationError {
            let code: WorkspaceAPIError.Code
            switch error {
            case .notLive: code = .browserNotLive
            case .timedOut: code = .outcomeUnknown
            case .userTyping: code = .busy
            case .staleRef, .notVisible, .covered, .notEditable, .focusRefused: code = .targetConflict
            case .unknownKey, .script: code = .invalidRequest
            }
            return .error(WorkspaceAPIError(code: code, message: String(error.description.prefix(2048))))
        } catch {
            return .error(WorkspaceAPIError(code: .invalidRequest, message: "The browser action could not produce a JSON result."))
        }
    }
}
