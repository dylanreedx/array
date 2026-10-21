#if os(macOS)
import Darwin
import Foundation

/// Stand-in processes for the process-tracking witnesses (CoreChecks and the
/// app's `--agent-process-tracker-check`): a fake agent CLI and the jobs it
/// leaves running. Never used by a real launch.
public enum ProcessTrackingQAHelper {
    public static let flag = "--process-tracking-helper"

    /// Helper modes the live checks spawn. `listen <portfile>` binds 127.0.0.1:0,
    /// writes the port and sleeps; `setsid-listen` leaves its group first;
    /// `list-fds <file>` writes the descriptors it was born with; `agent <dir>`
    /// stands in for an agent CLI and starts the three jobs.
    ///
    /// The stand-in CLI is this binary, not a shell, because shells do not expose
    /// their environment to `KERN_PROCARGS2` (a zsh tool shell reads as untagged),
    /// and no real agent CLI is a shell.
    public static func run(_ arguments: [String]) -> Never {
        guard let mode = arguments.first, arguments.count >= 2 else { Foundation.exit(64) }
        let output = arguments[1]
        switch mode {
        case "portless-agent":
            // A real tool shell with a long-running child, and no socket. The
            // witness decides when the CLI returns, after observing the job.
            usleep(2_500_000)
            let shell = Process()
            shell.executableURL = URL(fileURLWithPath: "/bin/sh")
            // Deliberately scrub the owner tag: attribution must first use
            // ancestry, then retain that established ownership after adoption.
            shell.environment = ["PATH": "/usr/bin:/bin"]
            shell.arguments = ["-c", "printf '%s' \"$$\" > \"$1\"; /bin/sleep 60 & wait",
                               "array-portless-script", output + "/script.pid"]
            do { try shell.run() } catch { Foundation.exit(70) }
            let deadline = Date().addingTimeInterval(45)
            while !FileManager.default.fileExists(atPath: output + "/finish-agent"), Date() < deadline {
                usleep(20_000)
            }
            Foundation.exit(0)
        case "list-fds":
            let open = (0..<1024).filter { fcntl(Int32($0), F_GETFD) != -1 }
            try? open.map(String.init).joined(separator: " ").write(toFile: output, atomically: true, encoding: .utf8)
            Foundation.exit(0)
        case "agent":
            // Long enough that none of the jobs reads as part of the CLI itself.
            usleep(2_500_000)
            let me = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
            let launches: [(String, [String])] = [
                (me, [flag, "listen", output + "/plain.port"]),
                ("/usr/bin/env", ["-i", me, flag, "listen", output + "/scrubbed.port"]),
                ("/bin/sh", ["-c", "( \"$0\" --process-tracking-helper setsid-listen \"$1\" & )", me, output + "/detached.port"]),
            ]
            for (executable, arguments) in launches {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                try? process.run()
            }
            // `agent <dir> spare`: one more listener, started the raw way and
            // never waited for, so when something kills it it lingers as a
            // zombie, exactly as a job under a shell that has not reaped it.
            if arguments.count > 2, arguments[2] == "spare" {
                var pid: pid_t = 0
                let argv = [me, flag, "listen", output + "/spare.port"]
                var cArgs = argv.map { strdup($0) } + [nil]
                _ = posix_spawn(&pid, me, nil, nil, &cArgs, environ)
                cArgs.forEach { free($0) }
            }
            sleep(60)
            Foundation.exit(0)
        case "listen", "setsid-listen":
            if mode == "setsid-listen" { _ = setsid() }
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
            _ = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            listen(fd, 4)
            var actual = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &actual) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }
            try? String(UInt16(bigEndian: actual.sin_port)).write(toFile: output, atomically: true, encoding: .utf8)
            sleep(60)
            Foundation.exit(0)
        default:
            Foundation.exit(64)
        }
    }
}
#endif
