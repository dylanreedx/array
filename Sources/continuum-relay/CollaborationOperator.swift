import Foundation
import ContinuumRevivedCollaborationService

/// Operator commands that run against the collaboration database alone:
///
///     continuum-relay --collaboration-backup <new backup path>
///     continuum-relay --collaboration-verify-backup <backup path>
///     continuum-relay --collaboration-restore <backup path>
///     continuum-relay --collaboration-list-people
///     continuum-relay --collaboration-recover-person <person id>
///
/// They read RELAY_COLLABORATION_DATABASE_PATH and RELAY_COLLABORATION_MASTER_KEY
/// and never open the companion database. Backup commands print a counts-only
/// report; recovery prints a one-time enrollment, which is admission material.
/// Returns nil when the arguments are not one of these commands.
func runCollaborationOperatorCommand(_ arguments: [String]) async -> Int32? {
    let commands = ["--collaboration-backup", "--collaboration-verify-backup", "--collaboration-restore",
                    "--collaboration-list-people", "--collaboration-recover-person"]
    guard arguments.count > 1, commands.contains(arguments[1]) else { return nil }
    let environment = ProcessInfo.processInfo.environment
    let expectedCount = arguments[1] == "--collaboration-list-people" ? 2 : 3
    guard arguments.count == expectedCount, let livePath = environment["RELAY_COLLABORATION_DATABASE_PATH"],
          let secret = environment["RELAY_COLLABORATION_MASTER_KEY"],
          let key = Data(base64Encoded: secret), key.count >= 32 else {
        log("error", "invalid_operator_command", fields: ["command": arguments[1]]); return 2
    }
    let path = arguments.count > 2 ? arguments[2] : ""
    do {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        if arguments[1] == "--collaboration-list-people" || arguments[1] == "--collaboration-recover-person" {
            let store = try CollaborationStore(path: livePath, masterKey: key)
            if arguments[1] == "--collaboration-list-people" {
                FileHandle.standardOutput.write(try encoder.encode(try await store.operatorPeople()))
            } else {
                guard let person = UUID(uuidString: path) else { throw CollaborationStoreError.invalidRequest }
                let recovery = try await store.operatorRecoverPerson(person)
                FileHandle.standardOutput.write(try encoder.encode(recovery.enrollment))
                FileHandle.standardOutput.write(Data("\n".utf8))
                log("info", "operator_recovered_person", fields: ["revoked_devices": "\(recovery.revokedDevices.count)"])
                return 0
            }
            FileHandle.standardOutput.write(Data("\n".utf8))
            return 0
        }
        var fields = ["command": arguments[1]]
        let report: CollaborationBackupReport
        switch arguments[1] {
        case "--collaboration-backup":
            report = try await CollaborationStore.backup(databaseAt: livePath, to: path, masterKey: key)
        case "--collaboration-verify-backup":
            report = try await CollaborationStore.verifyBackup(at: path, masterKey: key)
        default:
            let restored = try await CollaborationStore.restore(backup: path, to: livePath, masterKey: key)
            report = restored.report
            if let aside = restored.movedAside { fields["moved_aside"] = aside }
        }
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data("\n".utf8))
        log("info", "operator_command_completed", fields: fields)
        return 0
    } catch {
        log("error", "operator_command_failed", fields: ["command": arguments[1], "error": String(describing: error)])
        return 1
    }
}

/// Optional retention overrides; the built-in defaults apply when unset.
/// RELAY_COLLABORATION_OPERATION_TAIL, RELAY_COLLABORATION_OPERATION_AGE_SECONDS
/// and RELAY_COLLABORATION_COMPACTION_BATCH take non-negative integers. A
/// malformed value fails startup rather than silently keeping the defaults.
func collaborationRetentionFromEnvironment() throws -> CollaborationRetention {
    let environment = ProcessInfo.processInfo.environment, defaults = CollaborationRetention()
    func value(_ name: String, _ fallback: Int) throws -> Int {
        guard let raw = environment[name] else { return fallback }
        guard let parsed = Int(raw), parsed >= 0 else { throw CollaborationStoreError.invalidRequest }
        return parsed
    }
    return .init(operationTail: try value("RELAY_COLLABORATION_OPERATION_TAIL", defaults.operationTail),
                 operationAge: TimeInterval(try value("RELAY_COLLABORATION_OPERATION_AGE_SECONDS", Int(defaults.operationAge))),
                 compactionBatch: try value("RELAY_COLLABORATION_COMPACTION_BATCH", defaults.compactionBatch),
                 dispatchAuthorityWindow: defaults.dispatchAuthorityWindow)
}
