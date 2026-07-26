import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P4.3-auto-settle-inactivity.md
//
// The list has to drain itself. Two halves, because the setting and the rule it
// feeds live in different modules:
//
//   A · THE RESOLVER — defaults/off/clamp/typo, and that Settings ▸ Agents binds
//       the exact key the resolver reads (an unbound picker is inert).
//   B · THE BEHAVIOUR, through `InboxLifecycle.resolve` with the window this
//       config actually produces: threshold−1 stays active, threshold+1 settles,
//       the `.active` pin stays active regardless, and nil never auto-settles.
//
// Half B is deliberately driven by `resolvedFromDefaults(...).window` rather than
// a hand-written `3 * 86_400`: a days→seconds conversion that is wrong by a
// factor of 60 would pass a check that computes its own expectation.
//
// Negative tests observed red before the final code (each quoted at its check).
func runAgentAutoSettleConfigChecks() {
    // 1. The offered options: an explicit "Off" word (not an empty string — the
    //    packet's "Watch out"), every day option inside the range, no repeats,
    //    and the default offered as one of them.
    expect(AgentAutoSettleConfig.options.contains(AgentAutoSettleConfig.offOption),
           "options must offer an explicit Off, got \(AgentAutoSettleConfig.options)")
    expect(!AgentAutoSettleConfig.options.contains(""),
           "Off must not be spelled as an empty string, got \(AgentAutoSettleConfig.options)")
    expect(Set(AgentAutoSettleConfig.options).count == AgentAutoSettleConfig.options.count,
           "options must not repeat, got \(AgentAutoSettleConfig.options)")
    for days in AgentAutoSettleConfig.dayOptions {
        expect(days >= AgentAutoSettleConfig.minimumDays && days <= AgentAutoSettleConfig.maximumDays,
               "day option \(days) must lie in \(AgentAutoSettleConfig.minimumDays)...\(AgentAutoSettleConfig.maximumDays)")
    }
    expect(AgentAutoSettleConfig.options.contains(AgentAutoSettleConfig.defaultOption),
           "the default option \(AgentAutoSettleConfig.defaultOption) must be offered")
    expect(AgentAutoSettleConfig.defaultDays == 3,
           "the packet's default is 3 days, got \(AgentAutoSettleConfig.defaultDays)")

    // 2. Resolution. Negative test (red before green): returning
    //    `Resolution(days: nil)` for an unset key made "unset resolves to the
    //    default 3 days, got nil" fail.
    let suiteName = "AgentAutoSettleConfigChecks-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.removePersistentDomain(forName: suiteName)

    let unset = AgentAutoSettleConfig.resolvedFromDefaults(defaults: defaults)
    expect(unset.days == AgentAutoSettleConfig.defaultDays,
           "unset resolves to the default \(AgentAutoSettleConfig.defaultDays) days, got \(String(describing: unset.days))")
    expect(unset.window == TimeInterval(AgentAutoSettleConfig.defaultDays) * 86_400,
           "the window is days x 86,400 seconds, got \(String(describing: unset.window))")

    defaults.set(AgentAutoSettleConfig.offOption, forKey: AgentAutoSettleConfig.afterDaysKey)
    let off = AgentAutoSettleConfig.resolvedFromDefaults(defaults: defaults)
    expect(off.days == nil && off.window == nil,
           "Off must resolve to nil (auto-settle disabled), got \(String(describing: off.days))")

    defaults.set("14", forKey: AgentAutoSettleConfig.afterDaysKey)
    expect(AgentAutoSettleConfig.resolvedFromDefaults(defaults: defaults).days == 14,
           "a stored day count must win")

    // Clamped, not rejected: out of range still means what it says.
    defaults.set("0", forKey: AgentAutoSettleConfig.afterDaysKey)
    expect(AgentAutoSettleConfig.resolvedFromDefaults(defaults: defaults).days == AgentAutoSettleConfig.minimumDays,
           "below the floor clamps to \(AgentAutoSettleConfig.minimumDays)")
    defaults.set("-5", forKey: AgentAutoSettleConfig.afterDaysKey)
    expect(AgentAutoSettleConfig.resolvedFromDefaults(defaults: defaults).days == AgentAutoSettleConfig.minimumDays,
           "a negative window must never mean 'settle everything immediately'")
    defaults.set("1000", forKey: AgentAutoSettleConfig.afterDaysKey)
    expect(AgentAutoSettleConfig.resolvedFromDefaults(defaults: defaults).days == AgentAutoSettleConfig.maximumDays,
           "above the ceiling clamps to \(AgentAutoSettleConfig.maximumDays)")

    // A typo falls back to the default rather than switching the sweep off —
    // a silently disabled sweep is invisible until the list is a graveyard.
    defaults.set("three", forKey: AgentAutoSettleConfig.afterDaysKey)
    let typo = AgentAutoSettleConfig.resolvedFromDefaults(defaults: defaults)
    expect(typo.days == AgentAutoSettleConfig.defaultDays,
           "an unparseable value falls back to the default, got \(String(describing: typo.days))")

    // 3. Settings ▸ Agents binds the exact key, with this config's own options.
    //    Negative test: binding the field to "continuum.agents.autoSettleDays"
    //    (a plausible near-miss) made this fail.
    let agentsFields = SettingsSchema.sections().first { $0.id == "agents" }?.fields ?? []
    guard let field = agentsFields.first(where: { $0.key == AgentAutoSettleConfig.afterDaysKey }) else {
        expect(false, "Settings ▸ Agents must bind \(AgentAutoSettleConfig.afterDaysKey), got \(agentsFields.compactMap(\.key))")
        return
    }
    switch field {
    case let .choice(_, _, options, defaultValue):
        expect(options == AgentAutoSettleConfig.options,
               "the picker must offer this config's options, got \(options)")
        expect(defaultValue == AgentAutoSettleConfig.defaultOption,
               "the picker's default must be the config's, got \(defaultValue)")
    default:
        expect(false, "the auto-settle field must be a .choice (the packet's nullable-off spelling), got \(field)")
    }

    // 4. THE BEHAVIOUR, through the rule the setting exists to feed. The window
    //    comes from the resolver, so a wrong days→seconds conversion is caught
    //    here rather than reproduced.
    defaults.set("3", forKey: AgentAutoSettleConfig.afterDaysKey)
    let window = AgentAutoSettleConfig.resolvedFromDefaults(defaults: defaults).window
    expect(window == 3 * 86_400, "3 days must be 259,200s, got \(String(describing: window))")

    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let justInside = now.addingTimeInterval(-(3 * 86_400 - 3_600))   // threshold − 1h
    let justOutside = now.addingTimeInterval(-(3 * 86_400 + 3_600))  // threshold + 1h

    // Negative test: `>=` -> `<` on the inactivity comparison in
    // `InboxLifecycle.resolve` turned "inside the window an agent stays active"
    // red here, and P4.2's own week-of-silence witness red in AgentUIChecks.
    expect(InboxLifecycle.resolve(override: .neutral, lastActivityAt: justInside,
                                  autoSettleAfter: window, now: now) == .active,
           "inside the window an agent stays active")
    expect(InboxLifecycle.resolve(override: .neutral, lastActivityAt: justOutside,
                                  autoSettleAfter: window, now: now) == .settled(at: justOutside),
           "past the window an agent settles itself, dated when the work actually ended")

    // The keep-active pin suppresses it — the reason the override is a tri-state.
    expect(InboxLifecycle.resolve(override: .active, lastActivityAt: justOutside,
                                  autoSettleAfter: window, now: now) == .active,
           "an .active pin must survive any inactivity")

    // Off means off, however stale.
    defaults.set(AgentAutoSettleConfig.offOption, forKey: AgentAutoSettleConfig.afterDaysKey)
    let disabled = AgentAutoSettleConfig.resolvedFromDefaults(defaults: defaults).window
    let ancient = now.addingTimeInterval(-365 * 86_400)
    expect(InboxLifecycle.resolve(override: .neutral, lastActivityAt: ancient,
                                  autoSettleAfter: disabled, now: now) == .active,
           "with auto-settle Off nothing settles itself, however old")

    // And a blocker still outranks the sweep (P4.2's load-bearing rule, restated
    // here because auto-settle is the rule most likely to bury live work).
    expect(InboxLifecycle.resolve(override: .neutral, blockers: .pendingApproval,
                                  lastActivityAt: justOutside, autoSettleAfter: window, now: now) == .active,
           "an agent waiting on an approval must never auto-settle")

    print("AgentAutoSettleConfig checks passed: default 3 days, Off disables, out-of-range clamps, a typo falls back, Settings ▸ Agents binds the key, and the resolved window settles past the threshold while the pin and a blocker suppress it")
}
