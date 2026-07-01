# Scope OptionSet model — type-level observer isolation

## What this delivers

This ticket produces a `Scope` OptionSet in `ContinuumRevivedCore` that is the complete,
authoritative capability vocabulary for Continuum's control channel. When the iOS observer
is paired, the host issues it a token whose `Scope` is `.observer` — a set that contains
only `orchestrationRead`. That token is structurally incapable of representing a spatial
mutation: there is no `.orchestrationOperate`, no `.terminalOperate`, no capability to move
a tile, spawn a terminal, or send keystrokes. The impossibility is not a runtime check that
might be skipped; it is a consequence of the OptionSet type itself, making I5 (sync-boundary
purity) a type-level guarantee for the control leg from day one.

Beyond iOS, the same `Scope` model defines the two standing bundles (`observer` and
`operator`) and the administrative superset (`admin`) so that every future client — a
second Mac, a VPS daemon, a future web client — speaks the same vocabulary. A companion
per-message required-scope table enforces that a method with no declared scope entry fails
hard at call time, not silently through. No networking, no token machinery, no CloudKit is
built here. This ticket is purely the type definitions and their logic checks, standing up
the vocabulary that the pairing-token and connection-supervisor tickets will consume.

## How it fits

The scope model is declared standalone — it has no prerequisite tickets. It is consumed
immediately by the bootstrap-auth-on-every-path work, which seeds an in-memory admin grant
at Mac launch and enforces the `.observer`-only ceiling for iOS. It is also consumed by the
pairing-token ticket, which persists a `Scope` ceiling with each one-time pairing grant and
enforces the down-scope-only exchange rule. The iOS observer app and the APNS push service
both receive tokens whose `Scope` is `.observer`; without this type, those tickets cannot
describe what they are issuing. In short: nothing in Phase 6 that touches multi-device
capability can be specified or tested without this vocabulary.

## The approach

Implement `Scope` as a Swift `OptionSet` with `Int` raw values, `Codable`, `Hashable`, and
`Sendable`. Five atomic capability bits cover the full control-channel surface. Two
composite bundles (`observer`, `operator`) and the administrative superset are defined as
static properties on the type itself, following the same read/operate split that t3code
uses — which makes "observe-only" a subset rather than a boolean flag, so the iOS token
needs no special handling in the authorization function; it simply lacks the operate bits.

A `requiredScope` table maps every named control message to the minimum `Scope` bit it
needs. A free-function `authorize(_:grantedScopes:)` checks containment and throws a typed error
on failure. A missing entry in the table is itself a hard error — there is no "unscoped
message is implicitly allowed" path; this exactly mirrors t3code's `requiredScopeForMethod`
guard, which throws if a method has no entry, not if the session lacks the right scope.

Both the OptionSet type and the required-scope table live in `ContinuumRevivedCore` so they
are importable by the checks target without any app-layer dependency. No networking, no
Keychain access, no Apple framework beyond Foundation is needed.

## Where it lives

All new code is net-new. The existing `Registry.swift`
(`Sources/ContinuumRevivedCore/Registry.swift`) is the model for the file layout and
`Codable`/`Sendable` conventions to match.

**New files:**

- `Sources/ContinuumRevivedCore/Scope.swift` — the `Scope` OptionSet, the five bit
  constants, the three composite bundles, and the `Codable`/`Hashable`/`Sendable`
  conformances. No dependencies outside Foundation.
- `Sources/ContinuumRevivedCore/ScopeAuthorization.swift` — the `ControlMessage` enum
  (the closed set of named control messages), the `requiredScope` table, the `AuthError`
  error type, and the `authorize(_:grantedScopes:)` free function.

**Modified files:** none. The checks target imports `ContinuumRevivedCore` already
(`Sources/ContinuumRevivedCoreChecks/main.swift` top-of-file), so the new types are
immediately reachable there without build changes.

## Implementation breadcrumbs

### Scope.swift

```swift
// Sources/ContinuumRevivedCore/Scope.swift
public struct Scope: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    // Atomic bits — mirror the read / operate split so "observer" is a subset
    public static let orchestrationRead    = Scope(rawValue: 1 << 0) // read activity tree, snapshots
    public static let orchestrationOperate = Scope(rawValue: 1 << 1) // move tiles, spawn terminals
    public static let terminalOperate      = Scope(rawValue: 1 << 2) // send keystrokes to a pane
    public static let accessRead           = Scope(rawValue: 1 << 3) // list paired devices
    public static let accessWrite          = Scope(rawValue: 1 << 4) // pair or revoke a device

    // Composite bundles
    /// iOS observer: may subscribe to the activity projection; cannot mutate anything.
    public static let observer: Scope = [.orchestrationRead]
    /// Full Mac client: may observe and operate.
    public static let `operator`: Scope = [.orchestrationRead, .orchestrationOperate, .terminalOperate]
    /// Administrative: full operator rights plus device management.
    public static let admin: Scope    = [.operator, .accessRead, .accessWrite]
}
```

`Codable` is synthesized automatically because `Int` encodes cleanly.

### ScopeAuthorization.swift

```swift
// Sources/ContinuumRevivedCore/ScopeAuthorization.swift

/// Every control message a remote client may send. This enum is the authoritative
/// closed set — adding a new message requires adding an entry in `requiredScope`; there
/// is no path that allows an unscoped message through.
public enum ControlMessage: String, Sendable {
    case subscribeActivity   // observe the activity projection stream
    case subscribeSpatial    // observe the spatial op stream
    case moveTile            // mutate tile position
    case resizeTile          // mutate tile size
    case spawnTerminal       // create a new terminal window on the host
    case sendKeys            // write keystrokes into a remote pane
    case respondToApproval   // answer a managed-agent approval from iOS
    case listDevices         // enumerate paired sessions
    case pairDevice          // issue a new pairing grant
    case revokeDevice        // revoke a session or grant
}

/// The required scope for each control message. A message absent from this table is
/// an implementation error; `authorize` throws `AuthError.unscopedMessage` rather than
/// silently admitting the call.
public let requiredScope: [ControlMessage: Scope] = [
    .subscribeActivity:  .orchestrationRead,
    .subscribeSpatial:   .orchestrationRead,
    .moveTile:           .orchestrationOperate,
    .resizeTile:         .orchestrationOperate,
    .spawnTerminal:      .orchestrationOperate,
    .sendKeys:           .terminalOperate,
    .respondToApproval:  .orchestrationRead,   // approval response needs only read; the approval
                                               // handler validates the approval's ownership
    .listDevices:        .accessRead,
    .pairDevice:         .accessWrite,
    .revokeDevice:       .accessWrite,
]

public enum AuthError: Error, Sendable {
    case missingScope(Scope)         // session lacks the required bit
    case unscopedMessage(ControlMessage)  // message not in the required-scope table — hard fail
}

/// Authorizes a control message against the granted scope set.
/// Throws `AuthError.unscopedMessage` if the message has no required-scope declaration.
/// Throws `AuthError.missingScope` if the session's scope set does not contain the required bit.
public func authorize(_ message: ControlMessage, grantedScopes: Scope) throws {
    guard let required = requiredScope[message] else {
        throw AuthError.unscopedMessage(message)
    }
    guard grantedScopes.contains(required) else {
        throw AuthError.missingScope(required)
    }
}
```

The key guarantee: calling `authorize(.moveTile, grantedScopes: .observer)` always throws
`AuthError.missingScope(.orchestrationOperate)`, and this is a pure function the logic
checks can call a thousand times without any runtime setup.

## How we test it

### Logic (pure Core checks)

All checks go in `Sources/ContinuumRevivedCoreChecks/main.swift` under a clearly labelled
`// MARK: - Scope OptionSet` block, using the existing `expect(_:_:)` helper.

Exhaustive subset checks for the two bundles:

```swift
// observer is a strict subset of operator — it carries no operate bits
expect(Scope.observer.isSubset(of: .operator), "observer is a subset of operator")
expect(!Scope.observer.contains(.orchestrationOperate), "observer cannot operate orchestration")
expect(!Scope.observer.contains(.terminalOperate),      "observer cannot operate terminal")
expect(!Scope.observer.contains(.accessRead),           "observer cannot read device list")
expect(!Scope.observer.contains(.accessWrite),          "observer cannot manage devices")
```

Authorization function checks:

```swift
// Observer may subscribe; must not move a tile or send keys
try expect({ try authorize(.subscribeActivity, grantedScopes: .observer); return true }(),
           "observer may subscribeActivity")
try expect({
    do { try authorize(.moveTile, grantedScopes: .observer); return false }
    catch AuthError.missingScope { return true } catch { return false }
}(), "observer cannot moveTile — missing orchestrationOperate")
try expect({
    do { try authorize(.sendKeys, grantedScopes: .observer); return false }
    catch AuthError.missingScope { return true } catch { return false }
}(), "observer cannot sendKeys — missing terminalOperate")
```

Unscoped-message hard-fail (adding a new `ControlMessage` without a table entry is caught):

```swift
// Prove the table-exhaustion invariant with a synthetic missing-entry path.
// Rather than adding a real missing case, verify requiredScope's count equals
// ControlMessage.allCases.count so no case can be silently omitted.
// (Requires CaseIterable conformance on ControlMessage.)
expect(requiredScope.count == ControlMessage.allCases.count,
       "every ControlMessage has a declared required scope — no unscoped path exists")
```

Add `CaseIterable` to `ControlMessage` so this count check is always in sync.

Codable round-trip for Scope (covers I7):

```swift
let original: Scope = .admin
let data = try JSONEncoder().encode(original)
let decoded = try JSONDecoder().decode(Scope.self, from: data)
expect(original == decoded, "Scope round-trips through JSON without loss")
```

### Backend (real-path / integration)

Because `Scope` is a pure value type with no I/O, no network, and no system state, the
real-path check for this ticket is the scope enforcement path in the context where it will
actually fire: confirm that when the bootstrap-auth-on-every-path ticket wires up the
in-memory admin grant (the Mac's own process grant at launch), a local connection presenting
that grant passes `authorize` for every `ControlMessage`, and a synthetic `.observer` grant
fails for every operate message. This check is authored here, runs against the pure logic,
and the bootstrap-auth ticket inherits it as a real-path precondition.

Concretely in the checks target:

```swift
// All ControlMessage cases pass for admin
for msg in ControlMessage.allCases {
    try expect({ try authorize(msg, grantedScopes: .admin); return true }(),
               "admin may send any control message: \(msg.rawValue)")
}
// All operate messages fail for observer
let operateMessages: [ControlMessage] = [.moveTile, .resizeTile, .spawnTerminal, .sendKeys,
                                          .pairDevice, .revokeDevice]
for msg in operateMessages {
    try expect({
        do { try authorize(msg, grantedScopes: .observer); return false }
        catch AuthError.missingScope { return true } catch { return false }
    }(), "observer cannot send operate message: \(msg.rawValue)")
}
```

### UX (visual gate + dogfood snippet)

The `Scope` OptionSet has no visible UI of its own. The dogfood verification lives in the
pairing handshake that this ticket enables: once the pairing-token and iOS observer tickets
ship, the concrete dogfood snippet is:

Open Continuum on the Mac. Navigate to Settings > Devices > Pair a device (observe-only).
Scan the QR code on iPhone. The iPhone's session detail should read "Scope: observer" with
exactly the three labels "Activity", "Spatial" (read-only), and "Approvals" shown — and the
labels "Move tiles", "Send keys", and "Pair device" should be absent. Attempting to drag a
tile from the iPhone should produce no canvas change on the Mac.

For this ticket alone, the concrete visual gate is the checks binary output: run
`swift run ContinuumRevivedCoreChecks` and confirm zero `FAIL:` lines for the
`// MARK: - Scope OptionSet` block. That is the gate before any PR lands.

## Execution mode

Autonomous. Every deliverable — the OptionSet definition, the authorization function, the
required-scope table, and all logic checks — is pure Swift with no I/O, no app runtime, no
cloud account, no device. The checks binary exercises every invariant from the command line.
The matrix gate (`swift run ContinuumRevivedCoreChecks` exits 0) is necessary and
sufficient for this ticket; no human eye is required.

## Done when

- [ ] `Sources/ContinuumRevivedCore/Scope.swift` exists and compiles: five atomic bits,
  three composite bundles, `OptionSet + Codable + Hashable + Sendable` all satisfied.
- [ ] `Sources/ContinuumRevivedCore/ScopeAuthorization.swift` exists and compiles:
  `ControlMessage` (with `CaseIterable`), `requiredScope` table with exactly one entry per
  case, `AuthError`, and `authorize(_:grantedScopes:)`.
- [ ] `Scope.observer` is a strict subset of `Scope.operator` (checked by the logic suite).
- [ ] `Scope.observer` contains none of the operate or access bits (five individual checks).
- [ ] `authorize(.moveTile, grantedScopes: .observer)` throws `AuthError.missingScope`
  (checked by the logic suite).
- [ ] `authorize(.subscribeActivity, grantedScopes: .observer)` succeeds (checked).
- [ ] Every `ControlMessage.allCases` entry has a `requiredScope` entry — the count check
  passes (checked).
- [ ] `Scope` round-trips through `JSONEncoder`/`JSONDecoder` byte-identically (checked).
- [ ] `swift run ContinuumRevivedCoreChecks` exits 0 with no `FAIL:` lines.
- [ ] No existing checks regress.

## Depends on / unblocks

This ticket has no dependencies — it is standalone pure-Swift and can be built at any
point in Phase 6 without waiting on any other ticket. It directly unblocks the
bootstrap-auth-on-every-path work (which seeds a `.admin` grant at launch and enforces
`.observer` as the iOS ceiling), the pairing-token ticket (which stores a `Scope` ceiling
on each one-time grant and enforces down-scope-only exchange), the iOS observer app (which
receives a `.observer`-scoped session token), and the APNS push service (which fires only
for holders of `.orchestrationRead`). None of those tickets can specify or test their scope
assertions without the vocabulary this ticket establishes.

## Watch out for

**The hardest thing to get right is `respondToApproval` scope placement.** It is tempting
to gate it behind `.orchestrationOperate` because it "causes something to happen," but that
would prevent an `.observer` iOS client from answering approvals — which is the primary iOS
use case. The correct scope is `.orchestrationRead`, because the authorization for the
approval action itself lives in the approval handler (which validates that the session owns
the pending request), not in the transport gate. If you put `respondToApproval` behind an
operate bit, iOS approval is silently broken and the symptom is a `missingScope` error the
user sees as an unexplained rejection.

**Do not add a catch-all "allow if no entry" path.** The `requiredScope` table guard must
throw on a missing entry, not fall through. If you find yourself wanting a default, that is
a signal that a new `ControlMessage` case was added without a corresponding table entry —
add the entry, do not widen the gate.

**Codable rawValue stability.** The `Int` raw values for the five bits are serialized into
pairing grant records and session tokens. The bit positions chosen here (`1 << 0` through
`1 << 4`) must not be renumbered in later commits — if a new capability is added, assign it
the next unused bit (`1 << 5`), never reuse or reorder existing positions. Document this
constraint in a comment on the `rawValue` property.

**`CaseIterable` on `ControlMessage` is load-bearing.** The count-equality check between
`ControlMessage.allCases.count` and `requiredScope.count` is what prevents a future
developer from adding a case without a table entry. If `CaseIterable` is removed or the
conformance is synthesized incorrectly, that safety net silently disappears. Add a comment
noting that `CaseIterable` is required for the table-exhaustion check.
