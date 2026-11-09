import ContinuumRevivedCore
import Foundation

@MainActor
enum BrowserActionReporting {
    // Effect accounting only; ownership and permission gates stay in the service.
    static func isReadOnly(operation: String, payload: String) -> Bool {
        if operation == "browser.select",
           let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] {
            return object["options"] == nil || object["options"] is NSNull
        }
        return ["browser.snapshot", "browser.take_screenshot", "browser.console", "browser.wait_for"].contains(operation)
    }

    static func decorate(_ reply: WorkspaceAPIService.Reply, id: String, session: String,
                         started: Bool = false, expired: Bool = false, readOnly: Bool = false) -> WorkspaceAPIService.Reply {
        switch reply {
        case .result(var fields):
            guard fields["action"] == nil else { return reply }
            let action = BrowserActionResult(actionId: id, retrySessionId: session, state: .completed,
                effects: readOnly ? .none : .committed, retry: .none, freshSnapshotRequired: false)
            fields["action"] = WorkspaceAPIService.jsonObject(action).map { AnyHashableJSON(any: WorkspaceAPIService.plain($0)) }
            return .result(fields)
        case .error(var error):
            var action = error.action ?? BrowserActionResult(state: expired && !started ? .queueExpired : (started || error.code == .outcomeUnknown ? .outcomeUnknown : .rejected),
                effects: started || error.code == .outcomeUnknown ? .unknown : .none,
                retry: started || error.code == .outcomeUnknown ? .sameKeyOnly : .observeBeforeNewAction, freshSnapshotRequired: true)
            if action.actionId.isEmpty { action.actionId = id }
            if action.retrySessionId.isEmpty { action.retrySessionId = session }
            error.action = action
            if action.effects == .unknown && !error.message.contains("may have") {
                error.message += " Effects may have happened. Take a fresh snapshot; do not repeat with a new key."
            }
            return .error(error)
        case .cancelled:
            return reply
        }
    }
}
