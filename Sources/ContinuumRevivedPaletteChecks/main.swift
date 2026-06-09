import Foundation

@discardableResult
func runSwift(_ arguments: [String], captureOutput: Bool = false) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["swift"] + arguments

    let outputPipe = Pipe()
    if captureOutput {
        process.standardOutput = outputPipe
    }

    try process.run()
    process.waitUntilExit()

    let output: String
    if captureOutput {
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        output = String(data: data, encoding: .utf8) ?? ""
    } else {
        output = ""
    }

    return (process.terminationStatus, output)
}

let build = try runSwift(["build", "--product", "continuum-revived"])
guard build.status == 0 else {
    Foundation.exit(build.status)
}

let binPath = try runSwift(["build", "--show-bin-path"], captureOutput: true)
guard binPath.status == 0 else {
    Foundation.exit(binPath.status)
}

let appPath = URL(fileURLWithPath: binPath.output.trimmingCharacters(in: .whitespacesAndNewlines))
    .appendingPathComponent("continuum-revived")

let process = Process()
process.executableURL = appPath
process.arguments = ["--palette-duplicate-root-check"]
try process.run()
process.waitUntilExit()

Foundation.exit(process.terminationStatus)
