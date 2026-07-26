import ContinuumRevivedAgentUI
import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P4.5-snooze-presets.md
//
// Presets resolve to the right LOCAL WALL CLOCK, including across both DST
// transitions, and "this evening" hides when it is nearly evening.
//
// Everything below runs in a FIXED calendar — Gregorian, `America/New_York`,
// `en_US_POSIX` — with an injected `now` built from date components, so no check
// here reads a clock or a locale. New York is the timezone on purpose: it
// observes DST, and 2026's transitions (spring forward Sun 8 Mar, fall back Sun
// 1 Nov) straddle a Saturday 09:00, which is exactly where a "tomorrow at 09:00"
// computed by adding 86,400 seconds lands on the wrong hour.
//
// THE DST WITNESS IS A COMPARISON, per the packet: each transition check asserts
// both that `wakeDate` answers 09:00 AND that `now.addingTimeInterval(86_400)`
// answers 10:00 (spring) / 08:00 (fall). Asserting only the first would still
// pass if `TimeZone` resolution silently flattened to UTC and there were no DST
// boundary to get wrong; the naive half proves the day really is 23 or 25 hours
// long in this calendar.
//
// Negative tests run red before the code that satisfies them (quoted per check).

private let checkCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
}()

/// A local wall-clock instant in `checkCalendar`. Force-unwrapped deliberately: a
/// nil here is a broken fixture, and failing loudly at the first line beats
/// checking dates against a silently substituted default.
private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    checkCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

/// The local wall clock `date` reads as, as a comparable tuple.
private func wallClock(_ date: Date) -> String {
    let parts = checkCalendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    return String(
        format: "%04d-%02d-%02d %02d:%02d",
        parts.year!, parts.month!, parts.day!, parts.hour!, parts.minute!
    )
}

func runSnoozePresetChecks() {
    runSnoozePresetWallClockCheck()
    runEveningSuppressionCheck()
    runSnoozeDSTCheck()
    runNextWeekCheck()
    print("SnoozePreset checks: four wall-clock targets, evening suppressed within the hour, both DST transitions beaten against naive +86400, and next-week from Monday and Sunday passed")
}

// MARK: - 1 · Each preset's wall-clock target

// Negative test (red first): `case .tomorrow` returning
// `Self.time(hour: morningHour, onDayOf: now, ...)` — today rather than the next
// day — failed with "tomorrow: expected 2026-07-16 09:00, got 2026-07-15 09:00".
private func runSnoozePresetWallClockCheck() {
    // Wednesday 15 July 2026, 14:30 EDT. No DST anywhere near it: this check is
    // about the plain rule, and the transitions get their own.
    let now = at(2026, 7, 15, 14, 30)

    let expected: [(SnoozePreset, String)] = [
        (.inOneHour, "2026-07-15 15:30"),
        (.thisEvening, "2026-07-15 18:00"),
        (.tomorrow, "2026-07-16 09:00"),
        (.nextWeek, "2026-07-20 09:00"),  // the Monday after this Wednesday
    ]

    for (preset, wanted) in expected {
        let got = wallClock(preset.wakeDate(from: now, calendar: checkCalendar))
        expect(got == wanted, "\(preset.rawValue): expected \(wanted), got \(got)")
    }

    // The four cases really are four, and `offered` draws them in that order —
    // so a fifth preset cannot be added without this check being updated.
    expect(
        SnoozePreset.allCases.map(\.rawValue) == ["inOneHour", "thisEvening", "tomorrow", "nextWeek"],
        "the preset vocabulary changed: \(SnoozePreset.allCases.map(\.rawValue))"
    )
    let options = SnoozePreset.offered(at: now, calendar: checkCalendar)
    expect(
        options.map(\.preset) == SnoozePreset.allCases,
        "at 14:30 all four presets are offered, in order; got \(options.map(\.preset.rawValue))"
    )
    // The copy and the date travel together, and the date is the same one
    // `wakeDate` answers for the same instant.
    expect(
        options.map(\.title) == ["In 1 hour", "This evening", "Tomorrow", "Next week"],
        "preset copy changed: \(options.map(\.title))"
    )
    for option in options {
        let direct = option.preset.wakeDate(from: now, calendar: checkCalendar)
        expect(
            option.wakeAt == direct,
            "\(option.preset.rawValue): the option's date (\(wallClock(option.wakeAt))) disagrees with wakeDate (\(wallClock(direct)))"
        )
        expect(
            option.wakeAt > now,
            "\(option.preset.rawValue) resolved to \(wallClock(option.wakeAt)), which is not in the future"
        )
    }
}

// MARK: - 2 · "This evening" hides when it is nearly evening

// Negative test (red first): `isOffered` returning `true` unconditionally failed
// with "at 17:30 'this evening' is 30 min away and must be suppressed".
private func runEveningSuppressionCheck() {
    let nearEvening = at(2026, 7, 15, 17, 30)
    expect(
        !SnoozePreset.thisEvening.isOffered(at: nearEvening, calendar: checkCalendar),
        "at 17:30 'this evening' is 30 min away and must be suppressed"
    )
    expect(
        !SnoozePreset.offered(at: nearEvening, calendar: checkCalendar).contains { $0.preset == .thisEvening },
        "at 17:30 `offered` still listed 'this evening'"
    )
    // The other three never hide — suppression is one preset's rule, not a
    // general one.
    expect(
        SnoozePreset.offered(at: nearEvening, calendar: checkCalendar).map(\.preset) == [.inOneHour, .tomorrow, .nextWeek],
        "suppression removed more than 'this evening': \(SnoozePreset.offered(at: nearEvening, calendar: checkCalendar).map(\.preset.rawValue))"
    )

    let morning = at(2026, 7, 15, 9, 0)
    expect(
        SnoozePreset.thisEvening.isOffered(at: morning, calendar: checkCalendar),
        "at 09:00 'this evening' is nine hours away and must be offered"
    )

    // The boundary, both sides of it: exactly an hour out is still offered, a
    // minute later is not.
    expect(
        SnoozePreset.thisEvening.isOffered(at: at(2026, 7, 15, 17, 0), calendar: checkCalendar),
        "at exactly 17:00 'this evening' is one hour away and must still be offered"
    )
    expect(
        !SnoozePreset.thisEvening.isOffered(at: at(2026, 7, 15, 17, 1), calendar: checkCalendar),
        "at 17:01 'this evening' is under an hour away and must be suppressed"
    )
    // After 18:00 the target is in the past, so it is suppressed rather than
    // offering a wake-up that has already happened.
    expect(
        !SnoozePreset.thisEvening.isOffered(at: at(2026, 7, 15, 21, 0), calendar: checkCalendar),
        "at 21:00 'this evening' is in the past and must be suppressed"
    )
}

// MARK: - 3 · Both DST transitions, against naive second arithmetic

// Negative tests (red first), two of them, because the packet's named bug has two
// severities:
//   · `case .tomorrow` computed as `now.addingTimeInterval(86_400)` outright —
//     dies at check 1 above with "tomorrow: expected 2026-07-16 09:00, got
//     2026-07-16 14:30" (it loses the hour entirely, DST or not).
//   · The subtler one, which is the reason this leg exists: `dayAfter` written as
//     `startOfDay(date.addingTimeInterval(86_400))`. Setting 09:00 afterwards
//     repairs it in the middle of any day, so it passes every other check in this
//     file — it was observed GREEN across the whole suite before the two
//     near-midnight cases below were added, and red on them after
//     ("spring forward at 23:30: tomorrow expected 2026-03-08 09:00, got
//     2026-03-09 09:00").
private func runSnoozeDSTCheck() {
    // Spring forward: Sun 8 Mar 2026, 02:00 EST → 03:00 EDT. Saturday is 23
    // hours long.
    let beforeSpring = at(2026, 3, 7, 9, 0)
    let springTomorrow = SnoozePreset.tomorrow.wakeDate(from: beforeSpring, calendar: checkCalendar)
    expect(
        wallClock(springTomorrow) == "2026-03-08 09:00",
        "spring forward: tomorrow expected 2026-03-08 09:00, got \(wallClock(springTomorrow))"
    )
    let springNaive = beforeSpring.addingTimeInterval(86_400)
    expect(
        wallClock(springNaive) == "2026-03-08 10:00",
        "the spring-forward fixture is not actually a 23-hour day: +86400 gave \(wallClock(springNaive))"
    )
    expect(
        springTomorrow != springNaive,
        "spring forward: calendar arithmetic and +86400 agreed, so this check proves nothing"
    )

    // Fall back: Sun 1 Nov 2026, 02:00 EDT → 01:00 EST. Saturday is 25 hours long.
    let beforeFall = at(2026, 10, 31, 9, 0)
    let fallTomorrow = SnoozePreset.tomorrow.wakeDate(from: beforeFall, calendar: checkCalendar)
    expect(
        wallClock(fallTomorrow) == "2026-11-01 09:00",
        "fall back: tomorrow expected 2026-11-01 09:00, got \(wallClock(fallTomorrow))"
    )
    let fallNaive = beforeFall.addingTimeInterval(86_400)
    expect(
        wallClock(fallNaive) == "2026-11-01 08:00",
        "the fall-back fixture is not actually a 25-hour day: +86400 gave \(wallClock(fallNaive))"
    )
    expect(
        fallTomorrow != fallNaive,
        "fall back: calendar arithmetic and +86400 agreed, so this check proves nothing"
    )

    // "Next week" crosses a transition too, and a multiple of 86,400 drifts the
    // same way: Sat 31 Oct → Mon 2 Nov, two calendar days that are 49 hours.
    let fallNextWeek = SnoozePreset.nextWeek.wakeDate(from: beforeFall, calendar: checkCalendar)
    expect(
        wallClock(fallNextWeek) == "2026-11-02 09:00",
        "fall back: next week expected 2026-11-02 09:00, got \(wallClock(fallNextWeek))"
    )
    expect(
        wallClock(beforeFall.addingTimeInterval(2 * 86_400)) == "2026-11-02 08:00",
        "the fall-back next-week fixture does not cross the transition"
    )

    // THE DAY-STEP ITSELF, not just the hour. Setting the hour afterwards
    // repairs a naive `+86_400` in the middle of the day, so a `dayAfter` written
    // in seconds survives every case above — it only breaks near midnight, where
    // a 23-hour day makes +86,400 skip a day and a 25-hour day makes it stay put.
    // These two cases are where that bug dies (each was observed red against
    // `startOfDay(date.addingTimeInterval(86_400))`, which the rest of this file
    // lets through).
    let lateBeforeSpring = at(2026, 3, 7, 23, 30)
    let lateSpringTomorrow = SnoozePreset.tomorrow.wakeDate(from: lateBeforeSpring, calendar: checkCalendar)
    expect(
        wallClock(lateSpringTomorrow) == "2026-03-08 09:00",
        "spring forward at 23:30: tomorrow expected 2026-03-08 09:00, got \(wallClock(lateSpringTomorrow))"
    )
    expect(
        wallClock(lateBeforeSpring.addingTimeInterval(86_400)) == "2026-03-09 00:30",
        "the late spring-forward fixture does not skip a day under +86400"
    )

    let earlyFall = at(2026, 11, 1, 0, 30)
    let earlyFallTomorrow = SnoozePreset.tomorrow.wakeDate(from: earlyFall, calendar: checkCalendar)
    expect(
        wallClock(earlyFallTomorrow) == "2026-11-02 09:00",
        "fall back at 00:30: tomorrow expected 2026-11-02 09:00, got \(wallClock(earlyFallTomorrow))"
    )
    expect(
        wallClock(earlyFall.addingTimeInterval(86_400)) == "2026-11-01 23:30",
        "the early fall-back fixture does not stay inside the same day under +86400"
    )

    // `.inOneHour` is the one preset that means ELAPSED time, so on the
    // spring-forward morning it deliberately DOES move the wall clock two hours:
    // 01:30 EST + 1h is 03:30 EDT, because 02:30 does not exist locally.
    let duringSpring = at(2026, 3, 8, 1, 30)
    let anHourOn = SnoozePreset.inOneHour.wakeDate(from: duringSpring, calendar: checkCalendar)
    expect(
        wallClock(anHourOn) == "2026-03-08 03:30",
        "in 1 hour from 01:30 on the spring-forward day expected 2026-03-08 03:30, got \(wallClock(anHourOn))"
    )
    expect(
        anHourOn.timeIntervalSince(duringSpring) == 3_600,
        "'in 1 hour' must be one hour of real time, got \(anHourOn.timeIntervalSince(duringSpring))s"
    )

    // The other half of the same rule, raised by cross-review (codex, gpt-5.5):
    // fall-back is the REPEATED hour, where 01:30 happens twice and component
    // arithmetic is easiest to get wrong. An hour on from the first 01:30 EDT is
    // the second 01:30 EST — the wall clock does not move at all, and that is
    // correct: "in 1 hour" is a promise about elapsed time, so the 3,600 seconds
    // is the assertion that matters and the unchanged clock is the documented
    // consequence.
    let duringFall = at(2026, 11, 1, 1, 30)
    let anHourOnFall = SnoozePreset.inOneHour.wakeDate(from: duringFall, calendar: checkCalendar)
    expect(
        anHourOnFall.timeIntervalSince(duringFall) == 3_600,
        "'in 1 hour' across the repeated hour must be one hour of real time, got \(anHourOnFall.timeIntervalSince(duringFall))s"
    )
    expect(
        wallClock(anHourOnFall) == "2026-11-01 01:30",
        "in 1 hour from the first 01:30 on the fall-back day is the second 01:30, got \(wallClock(anHourOnFall))"
    )
    expect(
        anHourOnFall > duringFall,
        "the two 01:30s are the same instant, so this fixture is not the repeated hour"
    )
}

// MARK: - 4 · Next week from a Monday and from a Sunday

// Negative test (red first): starting the weekday walk at `startOfDay(for: now)`
// instead of the next day failed with "next week from a Monday: expected
// 2026-07-20 09:00, got 2026-07-13 09:00" — a "next week" in the past.
private func runNextWeekCheck() {
    let fromMonday = SnoozePreset.nextWeek.wakeDate(from: at(2026, 7, 13, 10, 0), calendar: checkCalendar)
    expect(
        wallClock(fromMonday) == "2026-07-20 09:00",
        "next week from a Monday: expected 2026-07-20 09:00, got \(wallClock(fromMonday))"
    )

    let fromSunday = SnoozePreset.nextWeek.wakeDate(from: at(2026, 7, 19, 10, 0), calendar: checkCalendar)
    expect(
        wallClock(fromSunday) == "2026-07-20 09:00",
        "next week from a Sunday: expected 2026-07-20 09:00, got \(wallClock(fromSunday))"
    )

    // Every starting day of one week lands on a Monday 09:00 that is in the
    // future — the property, so a seventh day is not a special case somebody
    // forgot. Mon 13 Jul → Sun 19 Jul.
    for day in 13...19 {
        let now = at(2026, 7, day, 23, 30)
        let wake = SnoozePreset.nextWeek.wakeDate(from: now, calendar: checkCalendar)
        expect(
            checkCalendar.component(.weekday, from: wake) == 2,
            "next week from 2026-07-\(day) landed on weekday \(checkCalendar.component(.weekday, from: wake)), not Monday"
        )
        expect(
            checkCalendar.component(.hour, from: wake) == 9,
            "next week from 2026-07-\(day) landed at hour \(checkCalendar.component(.hour, from: wake)), not 09:00"
        )
        expect(wake > now, "next week from 2026-07-\(day) landed at \(wallClock(wake)), which is not in the future")
    }
}
