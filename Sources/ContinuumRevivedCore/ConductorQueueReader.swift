import Foundation

public struct ConductorQueueTask: Equatable, Sendable {
    public let id: String
    public let projectId: String?
    public let projectName: String?
    public let category: String
    public let phase: Int
    public let description: String
    public let status: String
    public let priority: Int
    public let attemptCount: Int
    public let updatedAt: Int?

    public init(
        id: String,
        projectId: String?,
        projectName: String?,
        category: String,
        phase: Int,
        description: String,
        status: String,
        priority: Int,
        attemptCount: Int,
        updatedAt: Int?
    ) {
        self.id = id
        self.projectId = projectId
        self.projectName = projectName
        self.category = category
        self.phase = phase
        self.description = description
        self.status = status
        self.priority = priority
        self.attemptCount = attemptCount
        self.updatedAt = updatedAt
    }
}

public struct ConductorQueueSnapshot: Equatable, Sendable {
    public let tasks: [ConductorQueueTask]
    public let warnings: [String]

    public init(tasks: [ConductorQueueTask], warnings: [String] = []) {
        self.tasks = tasks
        self.warnings = warnings
    }
}

public struct ConductorQueueReader: Sendable {
    public enum ReaderError: Error, Equatable, CustomStringConvertible {
        case sqliteUnavailable
        case sqliteFailed(exitCode: Int32, stderr: String)
        case timedOut
        case malformedJSON(String)

        public var description: String {
            switch self {
            case .sqliteUnavailable: return "sqlite3 executable unavailable"
            case let .sqliteFailed(exitCode, stderr): return "sqlite3 failed with exit code \(exitCode): \(stderr)"
            case .timedOut: return "sqlite3 timed out"
            case let .malformedJSON(message): return "malformed sqlite JSON: \(message)"
            }
        }
    }

    public var sqlitePath: String
    public var timeoutSeconds: TimeInterval

    public init(sqlitePath: String = "/usr/bin/sqlite3", timeoutSeconds: TimeInterval = 5) {
        self.sqlitePath = sqlitePath
        self.timeoutSeconds = timeoutSeconds
    }

    public func read(projectRoot: URL) throws -> ConductorQueueSnapshot {
        try read(databaseURL: projectRoot.appendingPathComponent(".conductor/conductor.db"))
    }

    public func read(databaseURL: URL) throws -> ConductorQueueSnapshot {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return ConductorQueueSnapshot(tasks: [])
        }

        let sql = """
        .timeout 1000
        .mode json
        SELECT
          tasks.id AS id,
          tasks.project_id AS projectId,
          projects.name AS projectName,
          tasks.category AS category,
          tasks.phase AS phase,
          tasks.description AS description,
          tasks.status AS status,
          tasks.priority AS priority,
          tasks.attempt_count AS attemptCount,
          tasks.updated_at AS updatedAt
        FROM tasks
        LEFT JOIN projects ON projects.id = tasks.project_id
        ORDER BY
          CASE tasks.status
            WHEN 'pending' THEN 0
            WHEN 'running' THEN 1
            WHEN 'blocked' THEN 2
            WHEN 'done' THEN 3
            WHEN 'archived' THEN 4
            ELSE 5
          END,
          tasks.priority DESC,
          tasks.updated_at ASC,
          tasks.id ASC;
        """

        let result = try runSQLite(databaseURL: databaseURL, sql: sql)
        do {
            let decoder = JSONDecoder()
            let records = try decoder.decode([SQLiteTaskRecord].self, from: Data(result.utf8))
            return ConductorQueueSnapshot(tasks: records.map(\.task))
        } catch {
            throw ReaderError.malformedJSON(error.localizedDescription)
        }
    }

    private func runSQLite(databaseURL: URL, sql: String) throws -> String {
        #if os(macOS)
        guard FileManager.default.isExecutableFile(atPath: sqlitePath) else {
            throw ReaderError.sqliteUnavailable
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sqlitePath)
        process.arguments = ["-readonly", databaseURL.path]

        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        let readGroup = DispatchGroup()
        let readQueue = DispatchQueue(label: "ConductorQueueReader.pipe-drain", attributes: .concurrent)
        var stdoutData = Data()
        var stderrData = Data()
        readGroup.enter()
        readQueue.async {
            stdoutData = output.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }
        readGroup.enter()
        readQueue.async {
            stderrData = error.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }

        try process.run()
        input.fileHandleForWriting.write(Data(sql.utf8))
        try? input.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            let killDeadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning {
                process.interrupt()
                throw ReaderError.timedOut
            }
            _ = readGroup.wait(timeout: .now() + 1)
            throw ReaderError.timedOut
        }

        _ = readGroup.wait(timeout: .now() + 1)
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw ReaderError.sqliteFailed(exitCode: process.terminationStatus, stderr: stderr)
        }
        return String(data: stdoutData, encoding: .utf8) ?? "[]"
        #else
        _ = databaseURL
        _ = sql
        throw ReaderError.sqliteUnavailable
        #endif
    }
}

private struct SQLiteTaskRecord: Decodable {
    let id: String
    let projectId: String?
    let projectName: String?
    let category: String
    let phase: Int
    let description: String
    let status: String
    let priority: Int
    let attemptCount: Int
    let updatedAt: Int?

    var task: ConductorQueueTask {
        ConductorQueueTask(
            id: id,
            projectId: projectId,
            projectName: projectName,
            category: category,
            phase: phase,
            description: description,
            status: status,
            priority: priority,
            attemptCount: attemptCount,
            updatedAt: updatedAt
        )
    }
}
