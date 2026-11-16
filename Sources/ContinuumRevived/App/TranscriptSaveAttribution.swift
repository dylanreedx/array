import ContinuumRevivedCore
import Foundation

/// Diagnostic labels for synchronous main-actor work in the fresh-archive save
/// path. A phase interval must never span an await: another task's work could
/// otherwise be attributed to it.
enum TranscriptSaveAttributionPhase: UInt8, CaseIterable {
    case preflightContinuation
    case absentHandoff
    case saveSetup
    case savePreparation
    case saveCompletion
    case debounceCompletion
    case characterPackCallback
    case helperCompletionRecovery
    case debounceCleanup
    case preflightSubmission

    var label: String {
        switch self {
        case .preflightContinuation: return "preflight continuation"
        case .absentHandoff: return "absent FIFO handoff"
        case .saveSetup: return "save setup"
        case .savePreparation: return "save preparation"
        case .saveCompletion: return "save completion"
        case .debounceCompletion: return "debounce completion"
        case .characterPackCallback: return "character pack callback"
        case .helperCompletionRecovery: return "helper completion recovery"
        case .debounceCleanup: return "debounce cleanup"
        case .preflightSubmission: return "preflight submission"
        }
    }
}

/// Opt-in storage for the transcript-save performance witness. The caller
/// installs the supervisor hook only when diagnosing; normal execution does
/// not create this buffer or take diagnostic clock samples. Storage is reserved
/// once before the first measured idle window, and reporting happens afterward.
@MainActor
final class TranscriptSaveAttribution {
    struct Stamp {
        let wall: UInt64
        let cpu: UInt64

        static func now() -> Stamp {
            precondition(Thread.isMainThread)
            return Stamp(wall: DispatchTime.now().uptimeNanoseconds,
                         cpu: clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID))
        }
    }

    private struct PhaseInterval {
        let phase: TranscriptSaveAttributionPhase
        let agentID: AgentID?
        let wallStart: UInt64
        let wallEnd: UInt64
        let cpuStart: UInt64
        let cpuEnd: UInt64
    }

    private struct Window {
        let wallStart: UInt64
        let wallEnd: UInt64
        let cpuStart: UInt64
        let cpuEnd: UInt64
    }

    private let phaseLimit: Int
    private let windowLimit: Int
    private var phases: [PhaseInterval] = []
    private var windows: [Window] = []
    private(set) var droppedPhases = 0
    private(set) var droppedWindows = 0

    init(phaseLimit: Int = 4096, windowLimit: Int = 2048) {
        self.phaseLimit = max(0, phaseLimit)
        self.windowLimit = max(0, windowLimit)
        phases.reserveCapacity(self.phaseLimit)
        windows.reserveCapacity(self.windowLimit)
    }

    /// The end timestamps are taken before invoking this method so recording
    /// overhead is not misrepresented as the measured phase itself.
    func recordPhase(_ phase: TranscriptSaveAttributionPhase, agentID: AgentID?,
                     wallStart: UInt64, wallEnd: UInt64, cpuStart: UInt64, cpuEnd: UInt64) {
        guard wallEnd >= wallStart, cpuEnd >= cpuStart else { droppedPhases += 1; return }
        guard phases.count < phaseLimit else { droppedPhases += 1; return }
        phases.append(PhaseInterval(phase: phase, agentID: agentID, wallStart: wallStart, wallEnd: wallEnd,
                                    cpuStart: cpuStart, cpuEnd: cpuEnd))
    }

    /// Capture the same CPU endpoints used by the performance assertion; the
    /// actual wall span shows when the nominal sleep resumed late.
    func recordWindow(wallStart: UInt64, wallEnd: UInt64, cpuStart: UInt64, cpuEnd: UInt64) {
        guard wallEnd >= wallStart, cpuEnd >= cpuStart else { droppedWindows += 1; return }
        guard windows.count < windowLimit else { droppedWindows += 1; return }
        windows.append(Window(wallStart: wallStart, wallEnd: wallEnd, cpuStart: cpuStart, cpuEnd: cpuEnd))
    }

    /// Call after the measured loop. Intervals may nest; the union is used for
    /// accounted CPU so overlapping phase samples are never counted twice.
    func printReport() {
        func ms(_ nanoseconds: UInt64) -> Double { Double(nanoseconds) / 1_000_000 }
        print("DIAG transcript-save attribution windows=\(windows.count) phases=\(phases.count) dropped-windows=\(droppedWindows) dropped-phases=\(droppedPhases)")
        for (index, window) in windows.enumerated() {
            let overlapping = phases.filter {
                $0.wallStart < window.wallEnd && $0.wallEnd > window.wallStart &&
                $0.cpuStart < window.cpuEnd && $0.cpuEnd > window.cpuStart
            }
            let intervals = overlapping.map { (max($0.cpuStart, window.cpuStart), min($0.cpuEnd, window.cpuEnd)) }
                .sorted { $0.0 < $1.0 }
            var union: UInt64 = 0
            var current: (UInt64, UInt64)?
            for interval in intervals {
                guard let prior = current else { current = interval; continue }
                if interval.0 <= prior.1 {
                    current = (prior.0, max(prior.1, interval.1))
                } else {
                    union += prior.1 - prior.0
                    current = interval
                }
            }
            if let current { union += current.1 - current.0 }
            let cpu = window.cpuEnd - window.cpuStart
            let accounted = min(union, cpu)
            print(String(format: "DIAG transcript-save window=%d wall=%.3fms cpu=%.3fms phased=%.3fms unaccounted=%.3fms",
                         index, ms(window.wallEnd - window.wallStart), ms(cpu), ms(accounted), ms(cpu - accounted)))
            for phase in overlapping.sorted(by: { $0.cpuStart < $1.cpuStart }) {
                let overlap = min(phase.cpuEnd, window.cpuEnd) - max(phase.cpuStart, window.cpuStart)
                print(String(format: "DIAG transcript-save window=%d phase=%@ agent=%@ overlap=%.3fms wall=%.3fms",
                             index, phase.phase.label, phase.agentID?.rawValue.uuidString ?? "global", ms(overlap),
                             ms(phase.wallEnd - phase.wallStart)))
            }
        }
    }
}
