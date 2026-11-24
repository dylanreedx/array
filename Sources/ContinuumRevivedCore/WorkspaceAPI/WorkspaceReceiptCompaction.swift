import Foundation

/// What a workspace-tool receipt looks like on the wire to the model. The
/// in-process contract (`AgentDelegateResult`, `AgentMessageResult`, …) stays
/// whole; only the transport copy drops fields that carry no information, so a
/// lead coordinating helpers does not re-read the same boilerplate every call.
///
/// Dropped, top level only:
/// - `presentationEffects` when every dimension is `preserved`;
/// - `steps` when every step `succeeded` or was `skipped`;
/// - `parentAgentId` beside a `childAgentId` (the parent is always the caller).
///
/// A receipt with `partial: true` is unusual and goes out whole. Nothing an
/// agent acts on is ever removed: operationId, retryOp, partial, refusal and
/// held reasons, and childAgentId stay.
public enum WorkspaceReceiptCompaction {
    public static func compact(_ object: [String: Any]) -> [String: Any] {
        if object["partial"] as? Bool == true { return object }
        var lean = object
        if let effects = lean["presentationEffects"] as? [String: Any],
           !effects.isEmpty, effects.values.allSatisfy({ $0 as? String == "preserved" }) {
            lean["presentationEffects"] = nil
        }
        if let steps = lean["steps"] as? [String: Any],
           !steps.isEmpty, steps.values.allSatisfy({ ($0 as? String).map(["succeeded", "skipped"].contains) == true }) {
            lean["steps"] = nil
        }
        if lean["childAgentId"] != nil { lean["parentAgentId"] = nil }
        return lean
    }
}
