# Claude notification hook install with one-time consent

## What this delivers

When a user runs Claude Code in a Continuum terminal tile, the system can now emit an
authoritative `needsAttention` signal for that tile — the orange pulse that means "Claude
is waiting for you" — by writing a small breadcrumb file that the observer watches. Before
touching anything in the user's `~/.claude/settings.json`, Continuum shows a one-time
consent prompt: "Continuum wants to add a notification hook to Claude so it can tell when
an agent needs you — Allow / Not now." If the user allows, the hook entry is written and
the consent decision is persisted, so the prompt never appears again. If the user declines
or dismisses, Continuum continues operating with honest under-claiming: the Claude tile
shows `working` or `idle` based on the session store alone, never a fabricated
`needsAttention`.

From the user's point of view: the first time they have a Claude tile focused, a small
non-blocking sheet appears. They click Allow once. From that point on, whenever Claude
sends a Notification event — a permission prompt, a question, a tool-use gate — the tile
border flips from blue to orange within 250 ms, matching what they see in every other
orange-border agent in the fleet. Without the hook, the tile is perfectly functional; it
just cannot distinguish "Claude is thinking" from "Claude is waiting for you."

## How it fits

This ticket implements the concrete, consent-gated half of the attention signal described
in locked decision D11 and the budget discipline in D13.

It sits on top of three sibling pieces that must land before it, because it produces a
value that only those pieces can consume. None of them exist in the current tree yet — they
are being built in parallel, and this ticket assumes their shape rather than their code:

- The **status derivation function and its signals struct** — the pure function that maps a
  bundle of per-tile signals to an `AgentStatus`, together with the value type that carries
  those signals. That struct is where the `hookBreadcrumbPresent: Bool` and
  `hookBreadcrumbAge: TimeInterval?` fields live, and the function is where the cascade
  branch that fires `.needsAttention` (when the breadcrumb is present and fresh) lives. This
  ticket does not define those fields or that branch — it relies on the derivation work
  having defined them first, and its only job is to give `hookBreadcrumbPresent` a real
  source of truth.
- The **Claude dotfile reader** — the reader that assembles the signals struct for a Claude
  tile, including reading the breadcrumb file off disk. This ticket adds one path helper to
  that reader and one small breadcrumb-parsing function.
- The **session observer with budgets** — the per-project observer that drives the reader
  and the derivation function on each budget-governed FSEvents watch cycle. This ticket's
  breadcrumb-watching path runs through that observer's debounce loop, not a separate poller.

This ticket is the missing prerequisite that makes `hookBreadcrumbPresent` ever become
`true` for a real observed Claude tile: without the hook installed, the breadcrumb file is
never written, so the field stays `false` no matter how well the other three pieces work.

The consent mechanism also establishes the general pattern for any future Continuum hook
installation — this is the first and, for now, only dotfile-write Continuum performs in
any agent's config directory. The read-only file watching that the Claude dotfile reader,
Codex reader, and Pi reader all perform requires no consent and is unaffected by this ticket.

**A note on `agentKind`.** The consent prompt fires the first time a Claude tile is
detected. The locked decision D14 replaces the free-typed `agentKind: String` with a closed
enum (`shell | claude | codex | pi | managed | unknown`), and that enum is the clean way to
express "this tile is Claude" as `agentKind == .claude`. That enum migration is a **separate
piece of work that has not landed** — the current tree still carries `agentKind` as a free
`String`. This ticket does **not** depend on the enum migration and must not block on it:
until the enum lands, detect Claude by the string comparison `agentKind == "claude"` (the
value the kind classifier already writes). The detection is a single comparison behind a
tiny helper, so swapping `"claude"` for `.claude` when the enum lands is a one-line change.
See "The approach" for the exact helper.

## The approach

There are three concrete pieces: a hook writer, a consent gate, and a breadcrumb watcher.
All three are additive — nothing in the existing Claude dotfile reader or the existing
`AgentStatusEngine` hysteresis engine is changed.

**Detecting a Claude tile (string-based, until the enum lands).** The consent trigger and
the "is this a Claude tile" check both go through one tiny helper so there is a single place
to change when the closed `agentKind` enum (D14) lands:

```swift
// One place to swap when the agentKind enum lands.
// Today agentKind is a free String; the classifier writes "claude" for a Claude tile.
func isClaudeTile(_ descriptor: AgentDescriptor) -> Bool {
    descriptor.agentKind == "claude"      // becomes: descriptor.agentKind == .claude
}
```

The rest of this ticket refers to this check as "the tile is Claude" — it never assumes an
enum case exists.

**The hook entry.** The Claude Code hooks schema (verified against `~/.claude/settings.json`
on 2026-06-30) stores hooks as a top-level `"hooks"` map where each key is an event name
and each value is an array of `{matcher, hooks}` objects. The Continuum-installed entry
targets two events: `Notification` (fires when Claude sends any notification, including
permission prompts and input requests) and `Stop` (fires when a turn ends). Both write the
same breadcrumb, so the observer learns about attention and about turn completion from one
mechanism. The command is a short shell one-liner that writes a small JSON file to a
stable path, then exits 0 so Claude is never blocked:

```sh
printf '{"event":"%s","ts":"%s"}' "$CLAUDE_HOOK_EVENT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  > "$HOME/.continuum/hooks/claude-breadcrumb-$CLAUDE_SESSION_ID.json"
```

The breadcrumb directory is `~/.continuum/hooks/`. Continuum creates it on first install
with mode 0700. Each breadcrumb file is keyed by `$CLAUDE_SESSION_ID` (the session UUID
that Claude passes in the hook environment — verified against the `sessions/<pid>.json`
`sessionId` field), so one file per active session, with no cross-session bleed.

The hook entry written into `~/.claude/settings.json` looks like:

```jsonc
"hooks": {
  "Notification": [
    {
      "matcher": "*",
      "hooks": [
        {
          "type": "command",
          "command": "printf '{\"event\":\"%s\",\"ts\":\"%s\"}' \"$CLAUDE_HOOK_EVENT\" \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\" > \"$HOME/.continuum/hooks/claude-breadcrumb-$CLAUDE_SESSION_ID.json\""
        }
      ]
    }
  ],
  "Stop": [
    {
      "matcher": "*",
      "hooks": [
        {
          "type": "command",
          "command": "printf '{\"event\":\"%s\",\"ts\":\"%s\"}' \"$CLAUDE_HOOK_EVENT\" \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\" > \"$HOME/.continuum/hooks/claude-breadcrumb-$CLAUDE_SESSION_ID.json\""
        }
      ]
    }
  ]
}
```

If a `"Notification"` or `"Stop"` key already exists in `settings.json` (the user has
their own hooks), the Continuum entry is appended to the existing array, not replaced.
Existing user hooks are never removed or modified. The full write is atomic: read the
current JSON, merge in the Continuum entries, write to a temp file, rename into place.

**The consent gate.** A `ClaudeHookConsentStore` value type in `ContinuumRevivedCore`
persists consent state to `~/.continuum/hooks/consent.json`. Fields: `granted: Bool`,
`grantedAt: Date?`, `declinedAt: Date?`. A consent decision is permanent — once granted
or declined, the prompt never appears again unless the user explicitly revokes via
Settings. Revocation is the "Remove hook" button in Settings (described below); it does
not reset the "never show again" flag, it instead removes the hook entries from
`~/.claude/settings.json` and sets `granted = false` but stores `revokedAt` so the prompt
can be re-shown if a future Claude tile starts and no hook is present.

The prompt is a macOS `NSAlert` sheet, anchored to the main window. It is shown once:
the first time Continuum detects a running Claude tile (via the `isClaudeTile` helper
above — the `agentKind == "claude"` string comparison until the D14 enum lands) and
`ClaudeHookConsentStore.granted == false && declinedAt == nil`.
The title is "Let Continuum watch for Claude's attention signals". The message is "Continuum
can add a notification hook to Claude Code so it knows when Claude is waiting for you —
for a permission prompt, a question, or a finished turn. This writes one entry to
~/.claude/settings.json. Read-only file watching is already active regardless." The two
buttons are "Allow" (default) and "Not Now". "Not Now" sets `declinedAt` and suppresses
the prompt indefinitely (the user can re-enable from Settings). It does not install the
hook.

**The breadcrumb watcher.** The session observer's debounced FSEvents watch (delivered by
the session-observer-with-budgets work, and modelled on the existing `RunArtifactsWatcher`
discipline at `Sources/ContinuumRevivedCore/RunArtifactsWatcher.swift:64-119`) is extended
to also watch `~/.continuum/hooks/claude-breadcrumb-<sessionId>.json` for each active Claude
session. On any file-modification event, the observer reads the breadcrumb's `ts` field,
computes the age as `now − ts`, and sets `hookBreadcrumbPresent = true` in the tile's next
signals batch if the age is less than the stale timeout (default 300 s — the same value the
existing `AgentStatusEngine.Configuration` uses for its `staleTimeout` default, and the same
value the status-derivation work should use for its breadcrumb-freshness window). The status
derivation function then emits `.needsAttention` from step 3 of its priority cascade. The
250 ms debounce budget from D13 applies — FSEvents fires, the debounce timer runs, then the
read happens.

## Where it lives

**New file:**

- `Sources/ContinuumRevivedCore/AgentObserver/ClaudeHookInstaller.swift` — contains
  `ClaudeHookInstaller` struct (the read-JSON/merge/atomic-write logic) and
  `ClaudeHookConsentStore` struct (the consent JSON persistence).

**Touched files:**

- `Sources/ContinuumRevivedCore/AgentObserver/ClaudeStateReader.swift` (the file the Claude
  dotfile reader lands in; that directory and file do not exist yet and are created by the
  reader work — this ticket only adds to it) — add a
  `breadcrumbURL(for sessionId: String) -> URL` computed property that returns
  `URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".continuum/hooks/claude-breadcrumb-\(sessionId).json")`. This is the canonical breadcrumb path for both the installer (which writes the hook command pointing here) and the watcher (which watches this URL). The path is not duplicated.

- `Sources/ContinuumRevived/App/ContinuumApp.swift` — add the consent-prompt trigger in
  the existing agent-detection path. The trigger point is where a tile is first confirmed
  to be Claude (around line 3799, in the region that drives `dockTile.badgeLabel` and the
  `needsAttention` count). Detect via the `isClaudeTile` helper (the `agentKind == "claude"`
  string comparison, until the D14 enum lands). Add a call to
  `ClaudeHookConsentStore.shared.promptIfNeeded(in: window)` there. `promptIfNeeded` is a
  no-op if consent has already been recorded.

- `Sources/ContinuumRevivedCore/AgentStatusEngine.swift` — no changes needed. This is the
  existing hysteresis engine; the breadcrumb-driven `.needsAttention` path lives in the
  separate status-derivation function (the signals-struct work), not here. This ticket does
  not touch this file — it is listed only to make explicit that it is deliberately left alone.

**New symbols:**

- `ClaudeHookInstaller` — `struct`, `Sendable`. Methods: `installIfNeeded(settingsURL: URL) throws`, `uninstall(from settingsURL: URL) throws`, `isInstalled(in settingsURL: URL) -> Bool`. The settings URL defaults to `URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")`.
- `ClaudeHookConsentStore` — `struct`, `Sendable`. Fields: `granted`, `grantedAt`, `declinedAt`, `revokedAt`. Class-level `shared` instance backed by `~/.continuum/hooks/consent.json`. Method: `promptIfNeeded(in window: NSWindow)` — shows the `NSAlert` sheet on `window`, calls `installIfNeeded` on Allow, persists the result.
- `ClaudeHookBreadcrumb` — `struct`, `Codable`, `Sendable`. Fields: `event: String`, `ts: Date`. The parser for the breadcrumb files.

## Implementation breadcrumbs

```swift
// ClaudeHookInstaller.swift

public struct ClaudeHookInstaller: Sendable {

    static let continuumHookId = "continuum-attention"   // sentinel to detect our own entry

    // The shell command the hook runs — no escaping errors, tested by round-trip
    static func breadcrumbCommand(breadcrumbDir: String) -> String {
        // $CLAUDE_HOOK_EVENT and $CLAUDE_SESSION_ID are injected by Claude Code at hook-run time
        "printf '{\"event\":\"%s\",\"ts\":\"%s\"}' \"$CLAUDE_HOOK_EVENT\" "
        + "\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\" "
        + "> \"\(breadcrumbDir)/claude-breadcrumb-$CLAUDE_SESSION_ID.json\""
    }

    public func isInstalled(in settingsURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else { return false }
        // Look for any hook entry whose command contains our sentinel breadcrumb dir
        let breadcrumbDir = breadcrumbDirURL().path
        return Self.allCommandStrings(in: hooks).contains { $0.contains(breadcrumbDir) }
    }

    public func installIfNeeded(settingsURL: URL) throws {
        guard !isInstalled(in: settingsURL) else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: breadcrumbDirURL(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let rawData = (try? Data(contentsOf: settingsURL)) ?? Data("{}".utf8)
        var root = (try JSONSerialization.jsonObject(with: rawData) as? [String: Any]) ?? [:]
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        let command = Self.breadcrumbCommand(breadcrumbDir: breadcrumbDirURL().path)
        let entry: [String: Any] = ["matcher": "*", "hooks": [["type": "command", "command": command]]]
        for event in ["Notification", "Stop"] {
            var arr = (hooks[event] as? [[String: Any]]) ?? []
            arr.append(entry)
            hooks[event] = arr
        }
        root["hooks"] = hooks
        let merged = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        // Atomic write: write to temp, rename
        let tmp = settingsURL.appendingPathExtension("continuum-tmp")
        try merged.write(to: tmp, options: .atomic)
        _ = try fm.replaceItemAt(settingsURL, withItemAt: tmp)
    }

    public func uninstall(from settingsURL: URL) throws {
        guard var data = try? Data(contentsOf: settingsURL),
              var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = root["hooks"] as? [String: Any] else { return }
        let breadcrumbDir = breadcrumbDirURL().path
        for event in ["Notification", "Stop"] {
            guard var arr = hooks[event] as? [[String: Any]] else { continue }
            arr.removeAll { entry in
                ((entry["hooks"] as? [[String: Any]])?.first?["command"] as? String)?.contains(breadcrumbDir) == true
            }
            if arr.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = arr }
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        let cleaned = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        let tmp = settingsURL.appendingPathExtension("continuum-tmp")
        try cleaned.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(settingsURL, withItemAt: tmp)
    }

    private func breadcrumbDirURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".continuum/hooks")
    }
}

// ClaudeHookConsentStore.swift (can live in the same file or a companion)

public final class ClaudeHookConsentStore: @unchecked Sendable {
    public static let shared = ClaudeHookConsentStore()

    private struct Consent: Codable {
        var granted: Bool
        var grantedAt: Date?
        var declinedAt: Date?
        var revokedAt: Date?
    }

    private var consent: Consent = .init(granted: false)
    private let storeURL: URL
    private let installer = ClaudeHookInstaller()

    private init() {
        storeURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".continuum/hooks/consent.json")
        consent = (try? JSONDecoder().decode(Consent.self, from: Data(contentsOf: storeURL))) ?? consent
    }

    // Call from the agent-detection path. No-op if already decided.
    @MainActor
    public func promptIfNeeded(in window: NSWindow) {
        guard !consent.granted && consent.declinedAt == nil && consent.revokedAt == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Let Continuum watch for Claude's attention signals"
        alert.informativeText = "Continuum can add a notification hook to Claude Code so it "
            + "knows when Claude is waiting for you — for a permission prompt, a question, or "
            + "a finished turn. This writes one entry to ~/.claude/settings.json. "
            + "Read-only file watching is already active regardless."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Not Now")
        alert.alertStyle = .informational
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                do {
                    try self.installer.installIfNeeded(settingsURL: claudeSettingsURL())
                    self.consent = Consent(granted: true, grantedAt: Date())
                } catch {
                    // Install failed: record declined so we don't re-prompt immediately;
                    // surface the error as a non-modal notification
                    self.consent = Consent(granted: false, declinedAt: Date())
                    NSLog("Continuum: hook install failed: \(error)")
                }
            } else {
                self.consent = Consent(granted: false, declinedAt: Date())
            }
            try? self.persist()
        }
    }

    public var isGranted: Bool { consent.granted }

    // Called from Settings "Remove Claude hook" button
    public func revoke() throws {
        try installer.uninstall(from: claudeSettingsURL())
        consent.granted = false
        consent.revokedAt = Date()
        try persist()
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(consent)
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try data.write(to: storeURL, options: .atomic)
    }

    private func claudeSettingsURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")
    }
}
```

**Breadcrumb reading** (added to the Claude dotfile reader — the `ClaudeStateReader` the
reader work introduces; this ticket adds `readBreadcrumb` and `breadcrumbURL` to it):

```swift
// Called by the SessionObserver's watch callback when the breadcrumb file changes
func readBreadcrumb(for sessionId: String) -> (present: Bool, ageSeconds: Double)? {
    let url = breadcrumbURL(for: sessionId)
    guard let data = try? Data(contentsOf: url),
          let crumb = try? JSONDecoder().decode(ClaudeHookBreadcrumb.self, from: data) else {
        return nil
    }
    let age = Date().timeIntervalSince(crumb.ts)
    return (present: true, ageSeconds: age)
}
```

The `SessionObserver` calls `readBreadcrumb` whenever FSEvents fires on the breadcrumb
file. It sets `signals.hookBreadcrumbPresent` and `signals.hookBreadcrumbAge` from the
result before calling `deriveAgentStatus`. If the breadcrumb is absent or unparseable,
both fields stay at their defaults (`false` / `nil`) and the derivation function falls
through to the working/idle/stale cascade normally — no fabrication.

## How we test it

### Logic (pure Core checks)

All logic checks run in `ContinuumRevivedCoreChecks` with no process spawning, no live
Claude process, and no real `~/.claude/settings.json`.

**Installer: round-trip write-and-read.** Provide a temp-directory-backed `settingsURL`
(use `FileManager.default.temporaryDirectory`). Write an initial JSON `{}` to it. Call
`installIfNeeded`. Read the file back, parse it, and assert: (1) `hooks.Notification` is
a non-empty array; (2) `hooks.Stop` is a non-empty array; (3) the command string in each
entry contains `~/.continuum/hooks/claude-breadcrumb-$CLAUDE_SESSION_ID.json`; (4)
`isInstalled` returns `true` after the call. Then call `installIfNeeded` again and assert
`isInstalled` still returns `true` but the array lengths did not grow — idempotency is
required.

**Installer: merge with existing user hooks.** Seed `settings.json` with a
`hooks.Notification` array that already contains one user entry (a different command).
Call `installIfNeeded`. Assert the existing entry is still present alongside the new
Continuum entry, and the array length is exactly 2. User hooks are never deleted.

**Installer: uninstall removes only ours.** After the merged-with-user-hooks setup above,
call `uninstall`. Assert the user's entry remains and the Continuum entry is gone. Assert
`isInstalled` returns `false`.

**Installer: uninstall on missing settings is a no-op.** Call `uninstall` with a URL to a
non-existent file. Assert no error is thrown.

**Breadcrumb parser: valid JSON round-trip.** Write a JSON string
`{"event":"Notification","ts":"2026-06-30T12:00:00Z"}` to a temp file. Call
`ClaudeStateReader.readBreadcrumb(for: sessionId)` with the session ID matching that
file's name. Assert `present == true` and `ageSeconds > 0` (the timestamp is in the past).

**Breadcrumb parser: missing file returns nil.** Call `readBreadcrumb` with a session ID
that has no breadcrumb file. Assert the return is `nil`, not a crash or a thrown error.

**Breadcrumb parser: stale breadcrumb.** Write a breadcrumb with a `ts` that is 400 seconds
in the past (beyond the 300 s stale-timeout default — the same value the existing
`AgentStatusEngine.Configuration` uses for its `staleTimeout` default). Read it back. Assert
`ageSeconds > 300`. The derivation function's cascade at step 3 checks the breadcrumb age
against that stale-timeout window; when age is 400, `hookBreadcrumbPresent` is technically
true but the age guard fails and the function falls through to working/idle — assert this
end-to-end by constructing the signals struct with `hookBreadcrumbPresent = true` and
`hookBreadcrumbAge = 400` and calling the status derivation function — expect `.idle` (or
`.working` if `isRunning` is true), never `.needsAttention`. (The signals struct, its
`hookBreadcrumbPresent` / `hookBreadcrumbAge` fields, and the derivation function are all
provided by the status-derivation work, which must land before this check can compile.)

**Consent store: initial state is undecided.** Construct a `ClaudeHookConsentStore`
seeded from a temp JSON file containing `{}` or from an absent file. Assert
`isGranted == false`.

**Consent store: persist-and-reload round-trip.** Grant consent (set granted + grantedAt).
Persist to a temp path. Re-load from that path. Assert `isGranted == true` and `grantedAt`
is equal (within 1 second).

### Backend (real-path / integration, not bypassed)

The real-path check exercises the actual write path against the user's real
`~/.claude/settings.json` — but only after explicitly checking that the installer gate
conditions are met and restoring the original file on exit. This is the only test that
touches the real dotfile; it is gated on a `CONTINUUM_HOOK_REALPATH=1` environment
variable so it never runs in CI without explicit opt-in.

1. Read `~/.claude/settings.json` and store the original bytes.
2. Call `ClaudeHookInstaller().installIfNeeded(settingsURL: realURL)`. Assert it does not
   throw.
3. Read the file again. Assert `isInstalled` returns `true`. Assert the file is valid JSON.
   Assert any pre-existing user hooks are still present.
4. Call `uninstall`. Assert `isInstalled` returns `false`. Assert user hooks are still present.
5. Restore the original bytes from step 1, regardless of whether steps 2–4 passed or
   threw, using a `defer` block that runs unconditionally.
6. Record in the manifest: `installed: true/false`, `uninstalled: true/false`,
   `userHooksPreserved: true/false`, `originalRestored: true`. Never record `{passed: true}`.

A second real-path check, run without the opt-in gate and without touching any real
settings file, exercises the full breadcrumb-watch path:

1. Create a temp directory for `~/.continuum/hooks/`.
2. Call `ClaudeHookInstaller().installIfNeeded` targeting a temp `settings.json`.
3. Manually write a breadcrumb file named `claude-breadcrumb-test-session-id.json` with
   `{"event":"Notification","ts":"<now - 10s>"}`.
4. Call `ClaudeStateReader.readBreadcrumb(for: "test-session-id")` with the reader pointed
   at the temp directory.
5. Assert `present == true` and `ageSeconds` is between 9 and 20.
6. Construct the signals struct with the Claude kind set (`agentKind = "claude"` today, or
   the enum case once D14 lands), `hookBreadcrumbPresent = true`,
   `hookBreadcrumbAge = ageSeconds`, `isRunning = true`. Call the status derivation function.
   Assert `.needsAttention`. (This step depends on the status-derivation work having landed,
   since it owns the signals struct and the derivation function.)
7. Record in the manifest: `breadcrumbAge`, `derivedStatus`, elapsed ms.

### UX (visual gate + dogfood snippet)

The visual gate confirms that a running Claude tile flips from blue to orange when the
hook fires, within the debounce window, without a manual refresh.

Open the app. Ensure a Claude Code session is running in at least one terminal tile — it
does not matter what it is doing; any idle Claude session suffices. If the consent sheet
has not yet appeared, it appears now and you click Allow. Wait 2 seconds for the installer
to complete.

Then trigger the hook manually: in the tile's shell or a separate terminal, run:

```sh
printf '{"event":"Notification","ts":"%s"}' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  > ~/.continuum/hooks/claude-breadcrumb-$(cat ~/.claude/sessions/*.json | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['sessionId'])" 2>/dev/null || echo test-session).json
```

Or more simply: in the Claude tile itself, type a prompt that triggers a permission prompt
(e.g. a Bash tool use in non-bypass mode). Within 250 ms of the hook file being written,
the tile's canvas border must flip from its current color (blue `working` or gray `idle`)
to orange with the diamond attention indicator. The sidebar row for that tile must
simultaneously update to show `needs you` with the orange dot.

Concrete dogfood snippet: Open the app → start a Claude session in a terminal tile →
click Allow on the consent sheet → in the Claude session, issue a command that triggers a
permission gate (or write the breadcrumb file manually as above) → see: the tile border
turns orange within 250 ms, the sidebar row shows "needs you" in orange, and the dock
badge count increments if it was previously 0.

To confirm revocation: open Settings → Agent Awareness → Claude Hook → click "Remove hook"
→ verify `~/.claude/settings.json` no longer contains the Continuum command string →
verify the orange border does not reappear after writing a new breadcrumb file manually
(because the hook is gone, no new breadcrumb will be written during real agent runs).

## Execution mode

**Supervised.** The core installer and breadcrumb-parser logic are pure and fully
exercised by the Logic checks. However, the consent prompt is an `NSAlert` sheet that
requires a real main window, and confirming it shows, dismisses correctly, and triggers
the install requires a running app. The visual gate — the orange border appearing within
250 ms of a hook file write — requires a real app run with a real Claude session or a
manually-written breadcrumb file. These two gates cannot be replaced by a matrix check
without spawning a full app under UI testing, which is outside the current test harness
scope. The implementer must run the dogfood snippet above and confirm the visual outcome
with their own eyes before marking this done.

## Done when

- [ ] `ClaudeHookInstaller` exists in `Sources/ContinuumRevivedCore/AgentObserver/ClaudeHookInstaller.swift`
  with `installIfNeeded`, `uninstall`, and `isInstalled` methods.
- [ ] `installIfNeeded` writes valid JSON to the target settings file, appending to
  existing hook arrays rather than replacing them, and is idempotent (a second call does
  not grow the array).
- [ ] `uninstall` removes only the Continuum-written entries, leaves all other hook entries
  intact, and does not throw when the settings file is absent.
- [ ] The breadcrumb directory is created at `~/.continuum/hooks/` with mode 0700 on
  first install.
- [ ] The breadcrumb file path matches the constant in `ClaudeStateReader.breadcrumbURL(for:)` —
  verified by reading the path string from the installed command and asserting it equals
  the URL the reader watches.
- [ ] `ClaudeHookConsentStore.shared.promptIfNeeded(in:)` is called from `ContinuumApp.swift`
  the first time a Claude tile is detected (via the `isClaudeTile` helper —
  `agentKind == "claude"` today, `agentKind == .claude` once the D14 enum lands), and is a
  no-op on every subsequent call after a decision is recorded.
- [ ] The consent sheet displays the exact title and message specified above, with "Allow"
  as the default button and "Not Now" as the cancel.
- [ ] Clicking "Allow" calls `installIfNeeded` and persists `granted = true` + `grantedAt`
  to `~/.continuum/hooks/consent.json`.
- [ ] Clicking "Not Now" persists `granted = false` + `declinedAt` and suppresses any
  future prompt for the lifetime of the store.
- [ ] `ClaudeStateReader.readBreadcrumb(for:)` returns `nil` for absent or unparseable
  files and `(present: true, ageSeconds: …)` for a valid file, with no thrown error in
  either case.
- [ ] All Logic checks listed above pass with no daemon, no subprocess, no network.
- [ ] The real-path integration check (CONTINUUM_HOOK_REALPATH=1) restores the original
  `~/.claude/settings.json` unconditionally via `defer`, regardless of test outcome.
- [ ] The dogfood snippet above has been executed: the tile border turns orange within
  250 ms of a breadcrumb file being written, and the sidebar shows `needs you`.
- [ ] Settings exposes a "Claude Hook" row under Agent Awareness with a "Remove hook"
  button that calls `ClaudeHookConsentStore.shared.revoke()`.
- [ ] `swift build` passes with no new warnings.

## Depends on / unblocks

**Depends on (all must land before this ticket, and none exist in the tree today):**

- **The session observer with budgets** — provides the debounced FSEvents watch that
  triggers breadcrumb reads. Without the observer running its 250 ms debounce loop, the
  breadcrumb file change is never picked up and `hookBreadcrumbPresent` stays false.
- **The status derivation function and its signals struct** — defines the signals struct
  along with its `hookBreadcrumbPresent` and `hookBreadcrumbAge` fields, and implements the
  cascade branch that fires `.needsAttention` when those fields are set fresh. This ticket
  supplies the source of truth for `hookBreadcrumbPresent`; it does not define the field or
  the branch.
- **The Claude dotfile reader** — the reader this ticket extends. This ticket adds
  `breadcrumbURL(for:)` and `readBreadcrumb` to it, and calls `breadcrumbURL` from the
  installer to verify the write side and the watch side agree on one path. The reader itself
  (its file, its directory `Sources/ContinuumRevivedCore/AgentObserver/`) is created by the
  reader work, not by this ticket.

**Not a dependency, but coordinated with:** the closed `agentKind` enum migration (locked
decision D14). This ticket detects Claude by the free-string comparison `agentKind ==
"claude"` and does not wait on the enum. When the enum migration lands, the single
`isClaudeTile` helper flips to `agentKind == .claude`.

**Unblocks:** the visual proof of end-to-end `.needsAttention` for observed Claude shell
tiles. Every downstream piece that depends on "the orange signal fires for a real Claude
tile" — the fleet dock badge update, the sidebar attention rollup, and the iOS push
trigger — depends on this ticket having landed and passed its dogfood gate.

## Watch out for

**The single hardest thing to get right is the atomic write to `~/.claude/settings.json`.**
Claude Code itself reads and writes this file; a torn write or a JSON-invalid result will
break every subsequent Claude invocation until the user manually fixes the file. The
atomic write pattern (write to `.continuum-tmp`, `replaceItemAt:withItemAt:`) is required,
not optional. The installer must also handle the case where `settings.json` does not yet
exist (write `{}` as the initial content before merging). If `settings.json` exists but
is not valid JSON (user has a hand-edited error), the installer must abort with a thrown
error and leave the file unchanged rather than overwriting it with partial data.

**Do not install the hook if consent has not been recorded as `granted == true`.** The
`promptIfNeeded` → `installIfNeeded` call chain enforces this, but any code path that
calls `installIfNeeded` directly — for example, a future "install now" button in Settings
— must also check `ClaudeHookConsentStore.shared.isGranted` first. A hook written without
consent is a trust violation even if the user later granted consent for something else.

**The `$CLAUDE_SESSION_ID` environment variable in the hook command is injected by Claude
Code at hook-run time — it is not a shell variable Continuum sets.** The command string
in the installed hook entry must contain the literal `$CLAUDE_SESSION_ID` unexpanded, so
that Claude Code expands it when it runs the hook. Verify this by reading the installed
command string from the JSON and asserting it contains the literal dollar-sign characters,
not a hardcoded UUID.

**The consent sheet must not block the main run loop.** Use `beginSheetModal(for:completionHandler:)`
(async sheet), not `runModal()`. A synchronous modal call will freeze the canvas and
FSEvents delivery while the sheet is visible, which is exactly the wrong behavior for a
tool that needs to continue watching files while the user thinks.

**Revocation must not re-show the consent prompt.** After `revoke()` sets `granted = false`
and `revokedAt = Date()`, the `promptIfNeeded` gate checks `revokedAt == nil` before
proceeding. If `revokedAt` is set, the user has consciously removed the hook and must not
be nagged again — they can re-enable it via Settings. Any change to the `promptIfNeeded`
gate logic must preserve this invariant.
