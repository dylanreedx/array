import Darwin
import Foundation
import GRDB

enum AuthDatabase {
    static let fileName = "auth.db"

    static func queue(at databaseURL: URL?, fileManager: FileManager = .default) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.busyMode = .timeout(2)
        guard let databaseURL else {
            return try DatabaseQueue(configuration: configuration)
        }
        try fileManager.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: databaseURL.path) {
            let fd = open(databaseURL.path, O_RDWR | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { throw AuthError.unknown }
            close(fd)
        }
        let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        chmod(databaseURL.path, S_IRUSR | S_IWUSR)
        return queue
    }

    static func url(in authDirectory: URL) -> URL {
        authDirectory.appendingPathComponent(fileName)
    }
}

func authConstantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
    let lhsBytes = [UInt8](lhs)
    let rhsBytes = [UInt8](rhs)
    var diff = UInt8(lhsBytes.count ^ rhsBytes.count)
    let maxCount = max(lhsBytes.count, rhsBytes.count)
    for index in 0..<maxCount {
        let left = index < lhsBytes.count ? lhsBytes[index] : 0
        let right = index < rhsBytes.count ? rhsBytes[index] : 0
        diff |= left ^ right
    }
    return diff == 0
}
