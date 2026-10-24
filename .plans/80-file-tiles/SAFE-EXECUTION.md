# Required execution isolation

Dylan’s performance session supplied these rules on 2026-10-24 after three host exits from inherited Ghostty/Breakpad task exception handlers. They apply to the primary agent and every subagent, in addition to the existing project/app/tmux isolation rules.

1. Prefix every command that runs something you built (test binaries, check executables, swift run, .build/debug/Array, swift test) with /tmp/exc-probe/noexc, for example: /tmp/exc-probe/noexc /tmp/array-zip-check-build/check. It clears the inherited handler, so a crash stays inside your own process.
2. Prefix swift build too (a compiler crash counts): /tmp/exc-probe/noexc swift build ...
3. Do not run the crashing secure-snapshot or zip check again until you have read why its try! fails. Fix the cause rather than retrying.
4. Pass these rules on, word for word, to any subagent you spawn.

Use this wrapper for standalone `swiftc` and Swift scripts too. This does not replace disposable project/app-support directories or tmux socket isolation. Do not remove the managed-agent marker. Do not touch Dylan’s production app to repair the handler in this task.

Read-before-retry findings: the secure snapshot fixture supplied `/var/...` through Foundation normalization, which can preserve that system symlink while the reader deliberately refuses symlink components. Tests must supply a genuinely canonical fixture path. The independent ZIP fixture writer appended twelve central-header zero bytes where the specification requires ten, producing a malformed 48-byte header against the expected 46 bytes. Fix the fixture and keep the reader strict. Original temporary harnesses used `fatalError`/uncaught throws; report failures normally and run all descendants through the wrapper.
