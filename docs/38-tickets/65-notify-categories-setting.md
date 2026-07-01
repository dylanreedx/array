# Notify categories: four user-toggleable push preferences

## What this delivers

Four user-configurable notification toggles — **Approval**, **Input**, **Completion**, and
**Failure** — that control which APNS pushes reach the user's iPhone. Each category maps
exactly onto one class of agent phase transition: approval requests, user-input requests,
successful completions, and fatal failures. All four default to `true`, so the fully
attentive experience ships out-of-the-box, and a user who dislikes completion pings can
turn that one off without silencing everything else.

From the user's point of view: opening the Settings sidebar and navigating to the Agents
section reveals four labeled toggles, one per category. Changes take effect immediately —
the persisted defaults are what the push sender consults on the very next qualifying
transition; no restart, no reconnect, no extra tap required.

From the system's point of view: this ticket installs the canonical `NotifyCategories`
type in `ContinuumRevivedCore` and wires it into the `SettingsSchema` so every later
ticket that actually fires a push has a well-typed, testable guard to call, not an ad-hoc
`UserDefaults.standard.bool(forKey:)` scattered across the push-send site.

## How it fits

This ticket builds directly on the `SettingsField` / `SettingsSchema` machinery that
already governs every user preference in Continuum (see `SettingsField.swift` and
`SettingsSchema.swift` in `Sources/ContinuumRevivedCore/`). Adding a section to
`SettingsSchema.sections()` and a companion config type is the entire recipe; the generic
settings renderer picks it up with no UI surgery, exactly as every prior preference has
done.

The categories are the gate that the APNS push service will consult before firing. That
service — `AgentPushService`, which wraps the APNS HTTP/2 channel and builds the push
payload from an `AgentAwarenessState` — is the direct downstream consumer. Without the
category preferences defined and persisted, the push sender cannot respect user intent;
this ticket removes that blocker.

Upstream, this ticket depends on nothing except the existing settings infrastructure
already in the tree. It does not depend on the session observer, the managed-agent tier,
or any CloudKit or transport work. It can land in any sprint; the only reason to land it
before the push sender is that landing it after means the sender ships with hardcoded
behavior and needs a follow-up to respect preferences. Land this first.

## The approach

Introduce a new enum type `NotifyCategories` in `ContinuumRevivedCore` following the
exact pattern of `SessionResumeConfig` and `FocusBorderConfig`: one static `userDefaultsKey`
string constant per toggle, one static default value (`true` for all four), and one static
reader function that returns the persisted value or the default when absent. Four categories,
four keys, four readers, all in one file.

The four categories are:

- **approval** — fires when an agent transitions into `needsAttention` because a pending
  approval request is open (corresponds to `waiting_for_approval` in t3code's phase
  vocabulary, `relay.ts:28` `notifyOnApproval`).
- **input** — fires when an agent enters `needsAttention` because it is waiting on a
  user-input question (corresponds to `waiting_for_input`, `notifyOnInput`).
- **completion** — fires when an agent reaches `done` (corresponds to `completed`,
  `notifyOnCompletion`).
- **failure** — fires when an agent reaches a terminal error phase (corresponds to
  `failed`, `notifyOnFailure`).

This mapping is not a coincidence: it is the exact four-way split that t3code's
`RelayAgentAwarenessPreferences` (`relay.ts:28`) defines for the same reason — the
interruptive categories (approval, input) and the terminal categories (completion, failure)
are the four phase families that a user could want to suppress independently.

The `NotifyCategories` type also exposes a single pure method
`allows(phase: AgentPushPhase) -> Bool` that the push sender calls. `AgentPushPhase` is
a four-case enum (`.approval`, `.input`, `.completion`, `.failure`) that the sender maps
from `AgentStatus` before consulting this gate. This keeps the sender's decision down to a
single boolean call, with no `UserDefaults` spelunking at the call site.

Finally, append a new `SettingsSection` with `id: "agents"` to `SettingsSchema.sections()`
carrying four `.toggle` fields bound to the four `NotifyCategories` keys. The section title
is "Agents" and the icon is `"bell.badge"`.

## Where it lives

**New file:**

- `Sources/ContinuumRevivedCore/NotifyCategories.swift` — the `AgentPushPhase` enum,
  the `NotifyCategories` config type, and the `allows(phase:)` method. No imports beyond
  `Foundation`.

**Edited files:**

- `Sources/ContinuumRevivedCore/SettingsSchema.swift:198` — append the `"agents"` section
  to the array returned by `SettingsSchema.sections()`. The section sits after the existing
  `"terminal"` section and before `"appearance"`.

The `AgentStatusEngine` in `Sources/ContinuumRevivedCore/AgentStatusEngine.swift` is not
touched. The four `AgentStatus` cases (`needsAttention`, `done`, plus the two incoming
failure/input cases when those land) are what the push sender will map into `AgentPushPhase`
before calling `allows(phase:)`, but that mapping lives in the push sender, not here.

## Implementation breadcrumbs

```swift
// Sources/ContinuumRevivedCore/NotifyCategories.swift

import Foundation

/// The four push-notification categories an agent transition can belong to.
/// The push sender maps an `AgentStatus` transition to one of these before
/// consulting `NotifyCategories.allows(phase:defaults:)`.
public enum AgentPushPhase: String, Sendable {
    case approval    // needsAttention via pending managed-agent approval
    case input       // needsAttention via waiting-for-user-input
    case completion  // done (agent run ended successfully)
    case failure     // failed (agent run ended in error)
}

/// Persisted defaults controlling which APNS push categories fire.
/// All four default to `true` (fully attentive out of the box).
/// Pattern mirrors `SessionResumeConfig` / `FocusBorderConfig`.
public enum NotifyCategories {
    public static let approvalKey   = "continuum.notify.approval"
    public static let inputKey      = "continuum.notify.input"
    public static let completionKey = "continuum.notify.completion"
    public static let failureKey    = "continuum.notify.failure"

    public static func approval(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: approvalKey) != nil
            ? defaults.bool(forKey: approvalKey) : true
    }
    public static func input(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: inputKey) != nil
            ? defaults.bool(forKey: inputKey) : true
    }
    public static func completion(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: completionKey) != nil
            ? defaults.bool(forKey: completionKey) : true
    }
    public static func failure(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: failureKey) != nil
            ? defaults.bool(forKey: failureKey) : true
    }

    /// Returns `true` when the user has enabled pushes for `phase`.
    /// Call this at the push send site before firing APNS.
    public static func allows(phase: AgentPushPhase,
                              defaults: UserDefaults = .standard) -> Bool {
        switch phase {
        case .approval:   return approval(defaults: defaults)
        case .input:      return input(defaults: defaults)
        case .completion: return completion(defaults: defaults)
        case .failure:    return failure(defaults: defaults)
        }
    }
}
```

```swift
// SettingsSchema.swift — append inside the array returned by sections()
// Insert AFTER the "terminal" section, BEFORE "appearance":

SettingsSection(
    id: "agents",
    title: "Agents",
    iconSystemName: "bell.badge",
    fields: [
        .info(label: "Choose which agent events send a push notification to your iPhone."),
        .toggle(key: NotifyCategories.approvalKey,   label: "Notify on Approval Request", default: true),
        .toggle(key: NotifyCategories.inputKey,      label: "Notify on Input Request",    default: true),
        .toggle(key: NotifyCategories.completionKey, label: "Notify on Completion",       default: true),
        .toggle(key: NotifyCategories.failureKey,    label: "Notify on Failure",          default: true),
    ]
),
```

The push sender (whichever ticket builds `AgentPushService`) will gate every outbound push
with a call like:

```swift
// At the push-send site — NOT part of this ticket, shown for orientation only:
guard NotifyCategories.allows(phase: phase) else { return }
// ... build payload and fire APNS
```

The implementation here is complete and self-contained; the push sender does not need to be
built for this ticket's work to be verified.

## How we test it

### Logic

Pure Core checks with a fake `UserDefaults` instance (never `.standard`). The suite covers
the full matrix of reading behavior:

1. **Default behavior.** Construct a fresh `UserDefaults(suiteName:)` with no written keys.
   Assert `allows(phase:)` returns `true` for all four phases — the "fully attentive"
   default must hold when nothing has been persisted.

2. **Opt-out persists.** Write `false` for `NotifyCategories.completionKey` into the fake
   defaults. Assert `allows(phase: .completion, defaults: fake)` returns `false`.
   Assert `allows(phase: .approval, defaults: fake)` remains `true` — disabling one
   category must not suppress another.

3. **Re-enable round-trips.** Write `false`, then `true` back. Assert `allows` returns
   `true` — confirms that enabling a previously-disabled category works, not just the
   initial opt-out.

4. **All four phases covered.** For each of `.approval`, `.input`, `.completion`,
   `.failure`: write `false`, assert `allows` is `false`; write `true`, assert `allows` is
   `true`. The loop must hit every case.

5. **`SettingsField.currentValue` reflects the toggle.** Instantiate the four
   `.toggle` fields from `SettingsSchema.sections()` (filter to the `"agents"` section).
   Write `false` for one key, call `currentValue(in: fakeDefaults)`, assert it returns
   `.bool(false)`. Confirms the schema binding is wired to the right key.

6. **`SettingsField.setValue` round-trips.** Call `.setValue(.bool(false), in: fakeDefaults)`
   on one of the four agent toggle fields, then read it back with `currentValue`. Assert it
   returned `.bool(false)`, confirming the field→key→defaults chain is intact in both
   directions.

### Backend

A real-path check that exercises the persisted setting through the live app's `UserDefaults`
suite — not a bypassed executor. Because `NotifyCategories` reads from `.standard` by
default, the check opens and closes the Settings panel in the running app to prove the
binding is live, not mocked:

1. Launch the app (normal, no test override).
2. Toggle "Notify on Completion" off in the Settings panel (Settings sidebar →
   Agents section → Notify on Completion toggle).
3. Quit and relaunch the app without clearing defaults.
4. Open Settings again. Assert the Notify on Completion toggle is still off — persistence
   across launches must hold. Assert the other three toggles are still on.
5. Call `NotifyCategories.allows(phase: .completion)` in a one-shot check binary or via a
   debug command palette action that prints the current gate values; confirm it returns
   `false`. This is the concrete proof that the toggle written through the UI lands in
   `UserDefaults.standard` at the key `NotifyCategories.completionKey`, which is the same
   key `allows(phase: .completion)` reads.

### UX

**Visual gate.** Open the Settings panel in the running app. Navigate to the "Agents"
section (should appear between "Terminal" and "Appearance" in the sidebar). Confirm four
labeled toggle rows appear: "Notify on Approval Request", "Notify on Input Request",
"Notify on Completion", "Notify on Failure". Each toggle must show its on/off state
faithfully; the section header must show the bell badge icon.

**Dogfood snippet.** Open the app → press the settings keybind (or choose the settings
palette launcher) → click "Agents" in the settings sidebar. You see four toggle rows, all
on. Click the "Notify on Completion" toggle off. The toggle visually flips to off
immediately. Close Settings. Reopen Settings → Agents. The toggle is still off. Turn it
back on. It flips back. No crash, no flash, no stale state.

## Execution mode

Supervised. The Logic checks are fully automatable in the core check suite with a fake
`UserDefaults`, and the backend check can be wired into the real-path suite. But the UX
visual gate — confirming the four toggle rows appear in the correct settings section with
the correct icon, labels, and live-bindings — requires a human to open the running app and
look. The dogfood snippet above is the concrete check. No cloud device, no iOS hardware,
and no APNS account is needed for this ticket; the preferences are all local and all
verifiable on the Mac.

## Done when

- [ ] `Sources/ContinuumRevivedCore/NotifyCategories.swift` exists with the `AgentPushPhase`
  enum (four cases: `approval`, `input`, `completion`, `failure`) and the `NotifyCategories`
  config type (four key constants, four reader functions, one `allows(phase:defaults:)`
  function).
- [ ] All four reader functions return `true` when no value is present in `UserDefaults`,
  confirmed by a Logic check.
- [ ] `allows(phase:)` returns `false` for a phase whose key is set to `false`, and `true`
  for all other phases, confirmed by a Logic check.
- [ ] Disabling and re-enabling a toggle round-trips correctly, confirmed by a Logic check.
- [ ] The `"agents"` section appears in `SettingsSchema.sections()` with `id: "agents"`,
  `iconSystemName: "bell.badge"`, and exactly four `.toggle` fields bound to the four
  `NotifyCategories` keys.
- [ ] Each `.toggle` field's `currentValue` and `setValue` round-trip correctly through a
  fake `UserDefaults`, confirmed by a Logic check.
- [ ] The backend real-path check passes: a toggle written off through the Settings UI
  persists across an app relaunch and is read as `false` by `NotifyCategories.allows`.
- [ ] The UX visual gate passes: all four toggle rows appear in the Agents section of the
  Settings panel in the live app, with the correct labels and initial states.

## Depends on / unblocks

This ticket has no prerequisite tickets — the `SettingsField` and `SettingsSchema`
machinery it extends is already in the tree and stable.

It unblocks the APNS push sender, which is the ticket that implements `AgentPushService`
and actually fires HTTP/2 APNS pushes. The push sender must call
`NotifyCategories.allows(phase:)` before sending; without the preferences defined and
persisted, it cannot respect user intent. This ticket is the one thing the push sender
needs from the settings layer that does not yet exist.

## Watch out for

**The key namespace is the contract.** The four `UserDefaults` key strings
(`continuum.notify.approval`, etc.) are the interface between this ticket and the push
sender. Any change to a key string after the push sender is built requires a matching
change there. Pick them once and treat them as stable from the moment the push sender
ships.

**Default-true is deliberate and must not drift.** If a reader function falls back to
`false` when no key is present, the user gets silent pushes on a fresh install: the agent
runs, something needs attention, and the phone never rings. The Logic check for "all four
return `true` on a blank `UserDefaults`" is the guard on this; do not skip it.

**The `AgentPushPhase` enum must cover every push-triggering case.** If the managed-agent
tier later adds a new terminal phase (say, a "cancelled" state), `AgentPushPhase` and its
`allows` switch must be extended. A non-exhaustive switch would silently drop a new
category; the Swift compiler's exhaustiveness check is the safety net, so the switch
must never carry a `default:` branch.

**The settings section order is visible to users.** Inserting "Agents" after "Terminal"
and before "Appearance" keeps push-related preferences grouped near the agent / session
features rather than buried at the end. If the order in `SettingsSchema.sections()` drifts
from this intent during a merge conflict, the visual gate will catch it.
