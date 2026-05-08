import ContinuumRevivedCore
import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        Foundation.exit(1)
    }
}

do {
    let resolver = ShellLaunchResolver(environment: ["SHELL": "/bin/zsh"])
    let profile = try resolver.resolveShell(cwd: "/tmp/continuum")
    expect(profile.command == "/bin/zsh", "resolver should prefer SHELL")
    expect(profile.arguments == [], "shell profile should not add arguments")
    expect(profile.cwd == "/tmp/continuum", "shell profile should preserve cwd")
    expect(profile.title == "Shell", "shell profile title should be Shell")
}

do {
    let resolver = ShellLaunchResolver(environment: [:])
    let profile = try resolver.resolveShell(cwd: "/tmp/continuum")
    expect(profile.command == "/bin/zsh", "resolver should fall back to /bin/zsh")
}

do {
    var state = TerminalRuntimeState(status: .configuring)
    state.markRunning()
    expect(state.status == .running, "state should mark running")
    state.markExited(exitCode: 0)
    expect(state.status == .exited(exitCode: 0), "state should mark exited")
    state.markError("spawn failed")
    expect(state.status == .error(message: "spawn failed"), "state should mark errors")
}

print("ContinuumRevivedCoreChecks passed")
