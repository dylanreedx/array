import Foundation
#if os(macOS)
import Darwin
#endif

public struct HarnessRunControlHandle: Equatable, Sendable {
    public var runId: String
    public var processGroupId: Int32
    public var pid: Int32?

    public init(runId: String, processGroupId: Int32, pid: Int32? = nil) {
        self.runId = runId
        self.processGroupId = processGroupId
        self.pid = pid
    }
}

public enum HarnessRunControlError: Error, Equatable, Sendable {
    case missingControlFile
    case malformedControlFile
    case runIdMismatch(expected: String, actual: String?)
    case invalidProcessGroup(Int32)
    case signalFailed(signal: Int32, errnoCode: Int32)
}

public enum HarnessRunControl {
    public static func readHandle(runDirectory: URL, expectedRunId: String) throws -> HarnessRunControlHandle {
        let url = runDirectory.appendingPathComponent("control.json", isDirectory: false)
        guard let data = try? Data(contentsOf: url) else { throw HarnessRunControlError.missingControlFile }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HarnessRunControlError.malformedControlFile
        }
        let actualRunId = object["runId"] as? String
        guard actualRunId == expectedRunId else {
            throw HarnessRunControlError.runIdMismatch(expected: expectedRunId, actual: actualRunId)
        }
        guard let pgid = exactInt32(object["processGroupId"]) else {
            throw HarnessRunControlError.malformedControlFile
        }
        guard pgid > 1 else { throw HarnessRunControlError.invalidProcessGroup(pgid) }
        return HarnessRunControlHandle(
            runId: expectedRunId,
            processGroupId: pgid,
            pid: exactInt32(object["pid"])
        )
    }

    public static func terminateProcessGroup(_ handle: HarnessRunControlHandle, graceSeconds: TimeInterval = 2.0, sleeper: (TimeInterval) -> Void = Thread.sleep(forTimeInterval:)) throws {
        try send(signal: SIGTERM, toProcessGroup: handle.processGroupId)
        sleeper(graceSeconds)
        if processGroupExists(handle.processGroupId) {
            try send(signal: SIGKILL, toProcessGroup: handle.processGroupId)
        }
    }

    public static func processGroupExists(_ pgid: Int32) -> Bool {
        kill(-pgid, 0) == 0 || errno == EPERM
    }

    private static func exactInt32(_ value: Any?) -> Int32? {
        guard let number = value as? NSNumber else { return nil }
        let doubleValue = number.doubleValue
        guard doubleValue.isFinite,
              doubleValue.rounded(.towardZero) == doubleValue,
              doubleValue >= Double(Int32.min),
              doubleValue <= Double(Int32.max) else { return nil }
        return number.int32Value
    }

    private static func send(signal: Int32, toProcessGroup pgid: Int32) throws {
        guard pgid > 1 else { throw HarnessRunControlError.invalidProcessGroup(pgid) }
        if kill(-pgid, signal) != 0, errno != ESRCH {
            throw HarnessRunControlError.signalFailed(signal: signal, errnoCode: errno)
        }
    }
}
