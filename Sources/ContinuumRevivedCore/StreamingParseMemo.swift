import ContinuumRevivedAgentContent
import Foundation

/// The last open-stream parse per agent thread, so the display document and the
/// durable mirror of one agent, which ingest the very same events, parse a streamed
/// reply once between them.
///
/// A hit needs the same entry ID, the same source text and the same previous blocks,
/// the three inputs the parse is a function of, so it can only return what the other
/// projection would have computed. Anything else is a miss and parses as before. One
/// slot per thread, dropped when the stream closes.
final class StreamingParseMemo: @unchecked Sendable {
    static let shared = StreamingParseMemo()

    private struct Slot {
        var entryID: AgentNodeID
        var source: String
        var previous: [AgentBlock]
        var blocks: [AgentBlock]
        var cache: AgentStreamingParseCache
    }

    private let lock = NSLock()
    private var slots: [String: Slot] = [:]

    func lookup(thread: String, entryID: AgentNodeID, source: String,
                previous: [AgentBlock]) -> (blocks: [AgentBlock], cache: AgentStreamingParseCache)? {
        lock.lock(); defer { lock.unlock() }
        guard let slot = slots[thread], slot.entryID == entryID,
              slot.source == source, slot.previous == previous else { return nil }
        return (slot.blocks, slot.cache)
    }

    func store(thread: String, entryID: AgentNodeID, source: String, previous: [AgentBlock],
               blocks: [AgentBlock], cache: AgentStreamingParseCache) {
        lock.lock(); defer { lock.unlock() }
        slots[thread] = Slot(entryID: entryID, source: source, previous: previous, blocks: blocks, cache: cache)
    }

    func discard(thread: String) {
        lock.lock(); defer { lock.unlock() }
        slots[thread] = nil
    }
}
