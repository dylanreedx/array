import Darwin
import Foundation
import os

/// Names the work that blocks the main run loop, so a hitch in a camera gesture
/// can be attributed from the shipped log instead of guessed at.
///
/// Two halves, both near-zero cost and both main-thread only:
///
/// - `MainThreadActivity`: the big main-thread jobs bracket themselves with
///   `begin(label)` / `end`. A bracket that ran 1 ms or longer is remembered for
///   the current run-loop turn. Two clock reads and one append into storage
///   reserved at install, so nothing allocates per frame. Labels are
///   `StaticString`s, and carry no user text.
/// - `MainThreadStallWatchdog`: a pair of run-loop observers (wake and
///   about-to-sleep). A turn that ran longer than the threshold logs one line
///   under `continuum.canvas` / `stall`: how long, whether a camera gesture was
///   open, and the longest labelled jobs inside it. An idle app never wakes it and
///   never logs. No timers.
///
/// Read it with:
/// `log show --last 1h --predicate 'subsystem == "continuum.canvas" AND category == "stall"'`
enum MainThreadActivity {
    struct Entry {
        var label: StaticString
        var nanoseconds: UInt64
    }

    struct Token {
        let label: StaticString
        let start: UInt64
        func end() { MainThreadActivity.record(label, start: start) }
    }

    /// Jobs shorter than this are not worth remembering (and would crowd the turn).
    static let recordFloorNs: UInt64 = 1_000_000
    static let capacity = 16

    /// Completed jobs of the current run-loop turn, longest-first at report time.
    nonisolated(unsafe) static var turn: ContiguousArray<Entry> = {
        var storage = ContiguousArray<Entry>()
        storage.reserveCapacity(capacity)
        return storage
    }()

    /// Per-label totals since the gesture opened. A fixed table, searched
    /// linearly by label identity.
    nonisolated(unsafe) static var ledger: ContiguousArray<Entry> = {
        var storage = ContiguousArray<Entry>()
        storage.reserveCapacity(capacity)
        return storage
    }()
    nonisolated(unsafe) static var ledgerOpen = false

    @inline(__always) static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    @inline(__always) static func begin(_ label: StaticString) -> Token {
        Token(label: label, start: now())
    }

    static func record(_ label: StaticString, start: UInt64) {
        let elapsed = now() &- start
        guard elapsed >= recordFloorNs else { return }
        if turn.count < capacity { turn.append(Entry(label: label, nanoseconds: elapsed)) }
        guard ledgerOpen else { return }
        accumulate(label, elapsed)
    }

    private static func accumulate(_ label: StaticString, _ elapsed: UInt64) {
        for index in ledger.indices where same(ledger[index].label, label) {
            ledger[index].nanoseconds &+= elapsed
            return
        }
        if ledger.count < capacity { ledger.append(Entry(label: label, nanoseconds: elapsed)) }
    }

    static func same(_ a: StaticString, _ b: StaticString) -> Bool {
        a.utf8Start == b.utf8Start || a.description == b.description
    }

    /// A gesture opened: start a fresh ledger, seeded with this turn's jobs so the
    /// work that ran in the same turn as the first input is charged to it.
    static func openLedger() {
        ledger.removeAll(keepingCapacity: true)
        ledgerOpen = true
        for entry in turn { accumulate(entry.label, entry.nanoseconds) }
    }

    static func closeLedger() {
        ledgerOpen = false
    }

    /// "label 12.3, label 4.5" for the largest jobs, or "-" when nothing was tagged.
    static func summary(of entries: ContiguousArray<Entry>, limit: Int = 3) -> String {
        guard !entries.isEmpty else { return "-" }
        let top = entries.sorted { $0.nanoseconds > $1.nanoseconds }.prefix(limit)
        return top.map { String(format: "%@ %.1f", $0.label.description, Double($0.nanoseconds) / 1_000_000) }
            .joined(separator: ", ")
    }
}

enum MainThreadStallWatchdog {
    /// Anything shorter is ordinary frame work.
    nonisolated(unsafe) static var thresholdNs: UInt64 = 50_000_000
    /// At most this many lines per second; the rest are counted into the next line.
    static let maxLinesPerSecond = 4

    /// QA: receives each line the logger receives.
    nonisolated(unsafe) static var qaSink: ((String) -> Void)?
    /// QA: accumulate the observers' own cost and the main thread's busy time.
    nonisolated(unsafe) static var qaMeasureOverhead = false
    nonisolated(unsafe) static var qaObserverNs: UInt64 = 0
    nonisolated(unsafe) static var qaBusyNs: UInt64 = 0
    nonisolated(unsafe) static var qaLinesLogged = 0

    // Gesture state, written by the canvas.
    nonisolated(unsafe) private static var gestureOpen = false
    nonisolated(unsafe) private static var gestureTouchNs: UInt64 = 0
    nonisolated(unsafe) private static var gestureKindCode = 0 // 0 unknown, 1 pan, 2 zoom

    nonisolated(unsafe) private static var turnStartNs: UInt64 = 0
    nonisolated(unsafe) private static var windowStartNs: UInt64 = 0
    nonisolated(unsafe) private static var windowLines = 0
    nonisolated(unsafe) private static var suppressed = 0
    nonisolated(unsafe) private static var wakeObserver: CFRunLoopObserver?
    nonisolated(unsafe) private static var sleepObserver: CFRunLoopObserver?
    private static let logger = Logger(subsystem: "continuum.canvas", category: "stall")

    static var isInstalled: Bool { wakeObserver != nil }

    /// Idempotent. Order 0 on wake (as early as possible) and a late order on
    /// sleep, after Core Animation's commit and the canvas's frame-tail observer,
    /// so the commit counts toward the turn.
    static func install() {
        guard wakeObserver == nil else { return }
        let wake = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.afterWaiting.rawValue, true, 0
        ) { _, _ in
            let t = qaMeasureOverhead ? MainThreadActivity.now() : 0
            turnStartNs = MainThreadActivity.now()
            MainThreadActivity.turn.removeAll(keepingCapacity: true)
            if qaMeasureOverhead { qaObserverNs &+= MainThreadActivity.now() &- t }
        }
        let sleep = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 4_000_000
        ) { _, _ in
            let t = MainThreadActivity.now()
            let started = turnStartNs
            if started != 0 {
                let duration = t &- started
                if qaMeasureOverhead { qaBusyNs &+= duration }
                if duration >= thresholdNs { report(duration: duration, started: started) }
                turnStartNs = 0
            }
            if qaMeasureOverhead { qaObserverNs &+= MainThreadActivity.now() &- t }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), wake, .commonModes)
        CFRunLoopAddObserver(CFRunLoopGetMain(), sleep, .commonModes)
        wakeObserver = wake
        sleepObserver = sleep
    }

    /// QA teardown so a check can prove the pre-install state.
    static func uninstall() {
        if let wake = wakeObserver { CFRunLoopRemoveObserver(CFRunLoopGetMain(), wake, .commonModes) }
        if let sleep = sleepObserver { CFRunLoopRemoveObserver(CFRunLoopGetMain(), sleep, .commonModes) }
        wakeObserver = nil
        sleepObserver = nil
        turnStartNs = 0
    }

    // MARK: Gesture state

    /// The canvas saw gesture input or a camera step. Cheap: a clock read and
    /// three stores; the ledger is reset only on the opening edge.
    static func gestureTouched() {
        gestureTouchNs = MainThreadActivity.now()
        if !gestureOpen {
            gestureOpen = true
            gestureKindCode = 0
            MainThreadActivity.openLedger()
        }
    }

    static func gestureKind(zoom: Bool) {
        if zoom { gestureKindCode = 2 } else if gestureKindCode == 0 { gestureKindCode = 1 }
    }

    static var currentGestureKind: String {
        switch gestureKindCode { case 2: "zoom"; case 1: "pan"; default: "pending" }
    }

    static func gestureEnded() {
        gestureOpen = false
        MainThreadActivity.closeLedger()
    }

    /// The work charged to the gesture so far, formatted like a stall line's `ran`.
    static func gestureLedgerSummary() -> String {
        MainThreadActivity.summary(of: MainThreadActivity.ledger, limit: 4)
    }

    // MARK: Reporting

    private static func report(duration: UInt64, started: UInt64) {
        let now = MainThreadActivity.now()
        if now &- windowStartNs > 1_000_000_000 { windowStartNs = now; windowLines = 0 }
        guard windowLines < maxLinesPerSecond else { suppressed += 1; return }
        windowLines += 1
        // A gesture counts when it was touched since this turn began or shortly
        // before it (the input that woke the turn may predate the touch).
        let active = gestureOpen
            && (gestureTouchNs >= started || started &- gestureTouchNs < 500_000_000)
        let ran = MainThreadActivity.summary(of: MainThreadActivity.turn)
        var line = String(format: "stall: %.1f ms | gesture %@ | ran: %@",
                          Double(duration) / 1_000_000,
                          active ? currentGestureKind : "no", ran)
        if suppressed > 0 { line += " | +\(suppressed) more suppressed"; suppressed = 0 }
        qaLinesLogged += 1
        logger.notice("\(line, privacy: .public)")
        qaSink?(line)
    }
}
