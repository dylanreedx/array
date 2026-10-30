import Foundation
import ContinuumRevivedCollaborationService

/// Operator commands that run against the collaboration database alone:
///
///     continuum-relay --collaboration-backup <new backup path>
///     continuum-relay --collaboration-verify-backup <backup path>
///     continuum-relay --collaboration-restore <backup path>
///
/// They read RELAY_COLLABORATION_DATABASE_PATH and RELAY_COLLABORATION_MASTER_KEY
/// and never open the companion database. Output is a counts-only JSON report.
/// Returns nil when the arguments are not one of these commands.
func runCollaborationOperatorCommand(_ arguments: [String]) -> Int32? {
    let commands = ["--collaboration-backup", "--collaboration-verify-backup", "--collaboration-restore"]
    guard arguments.count > 1, commands.contains(arguments[1]) else { return nil }
    let environment = ProcessInfo.processInfo.environment
    guard arguments.count == 3, let livePath = environment["RELAY_COLLABORATION_DATABASE_PATH"],
          let secret = environment["RELAY_COLLABORATION_MASTER_KEY"],
          let key = Data(base64Encoded: secret), key.count >= 32 else {
        log("error", "invalid_operator_command", fields: ["command": arguments[1]]); return 2
    }
    let path = arguments[2]
    do {
        var fields = ["command": arguments[1]]
        let report: CollaborationBackupReport
        switch arguments[1] {
        case "--collaboration-backup":
            report = try CollaborationStore.backup(databaseAt: livePath, to: path, masterKey: key)
        case "--collaboration-verify-backup":
            report = try CollaborationStore.verifyBackup(at: path, masterKey: key)
        default:
            let restored = try CollaborationStore.restore(backup: path, to: livePath, masterKey: key)
            report = restored.report
            if let aside = restored.movedAside { fields["moved_aside"] = aside }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data("\n".utf8))
        log("info", "operator_command_completed", fields: fields)
        return 0
    } catch {
        log("error", "operator_command_failed", fields: ["command": arguments[1], "error": String(describing: error)])
        return 1
    }
}
