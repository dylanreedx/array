import Foundation
import ContinuumRevivedCore

extension WorkspaceAPIService {
    func deviceBuildResult(operationId: String, agentId: AgentID, checkout: CheckoutHandle) -> DeviceBuildOperationResult? {
        guard let job = deviceBuildJobs.jobs[operationId], job.scope.principal == agentId.rawValue,
              job.scope.checkout == checkout else { return nil }
        return deviceBuildJobs.result(job)
    }
    func deviceBuildRun(payload: [String: Any], scope: IOSPreviewAutomationSessions.Scope, root: URL,
                        authorized: @escaping () -> Bool) throws -> Reply {
        let request = try JSONDecoder().decode(DeviceBuildRequest.self, from: JSONSerialization.data(withJSONObject: payload))
        let caller = AgentID(rawValue: scope.principal)
        func response(_ job: IOSPreviewBuildJobs.Job) throws -> Reply {
            let data = try Self.encoder.encode(deviceBuildJobs.result(job))
            let value: [String: Any] = ["operationId": job.id, "deviceBuild": try JSONSerialization.jsonObject(with: data)]
            return .result(value.mapValues(AnyHashableJSON.init(any:)))
        }
        if request.kind == "cancel" {
            guard let id = request.operationId, let job = deviceBuildJobs.lookup(id: id, scope: scope) else {
                throw WorkspaceAPIError(code: .permissionDenied, message: "That build job is not owned by this caller and checkout.")
            }
            try deviceBuildJobs.cancel(id: id, scope: scope)
            return try response(job)
        }
        guard request.kind == "start", let sessionID = request.sessionId, let projectFile = request.projectFile,
              let scheme = request.scheme, let key = request.idempotencyKey, !key.isEmpty, key.utf8.count <= 128 else {
            throw WorkspaceAPIError(code: .invalidRequest, message: "Build start requires sessionId, checkout-relative projectFile, scheme and idempotencyKey (1–128 UTF-8 bytes). Cancel requires operationId.")
        }
        var normalized = request; normalized.idempotencyKey = nil
        let hash = IOSPreviewWorkspaceAPIState.digest(Data("device.build_run\n".utf8) + (try Self.encoder.encode(normalized)))
        let reservation = operations.reserve(agentId: caller, op: .deviceBuildRun, idempotencyKey: key,
            payloadHash: hash, operationId: UUID().uuidString)
        let id: String
        switch reservation {
        case let .reserved(record): id = record.operationId
        case let .replay(record):
            guard let job = deviceBuildJobs.lookup(id: record.operationId, scope: scope) else {
                throw WorkspaceAPIError(code: .targetConflict, message: "Build result expired. Query operation.get; do not repeat the build with a new key.")
            }
            return try response(job)
        case .conflict: throw WorkspaceAPIError(code: .idempotencyConflict, message: "That operation key has a different payload.")
        case .expired: throw WorkspaceAPIError(code: .targetConflict, message: "Build operation expired. Do not blindly repeat it.")
        }
        do {
            let job = try deviceBuildJobs.start(id: id, sessionID: sessionID, scope: scope, root: root,
                projectFile: projectFile, scheme: scheme, authorized: authorized) { [weak self] job in
                self?.operations.update(operationId: job.id) { record in
                    record.status = job.state == "succeeded" ? .committed : .failed
                    record.steps.attachment = job.state == "succeeded" ? .succeeded : .failed
                    record.steps.durability = job.state == "succeeded" ? .succeeded : .skipped
                    record.steps.presentation = .skipped
                    if job.state != "succeeded" { record.failureCode = job.state; record.failureMessage = "Build job settled as \(job.state). Inspect its bounded result; do not blindly repeat installation." }
                }
            }
            operations.update(operationId: id) { record in
                // Accepted service job is the creation effect. Even a failed or
                // cancelled build must not silently re-run on a same-key retry.
                record.steps.creation = .succeeded
                record.tileId = deviceAPI.sessions.attachments[sessionID]?.runtime.tileID
                record.steps.presentation = .skipped
            }
            return try response(job)
        } catch {
            operations.release(operationId: id)
            if let error = error as? IOSPreviewBuildJobs.Failure {
                throw WorkspaceAPIError(code: error == .busy ? .busy : .targetConflict, message: "Build job rejected before start: \(error).")
            }
            throw error
        }
    }
}
