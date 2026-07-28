--- a/Sources/Atlas/LedgerWriter.swift
+++ b/Sources/Atlas/LedgerWriter.swift
@@ -41,9 +41,12 @@ final class LedgerWriter {
     func rollSegment(reason: RollReason) {
-        guard state == .open else { return }
-        state = .rolling
-        publish(nextGeneration())
+        queue.async { [self] in
+            guard state == .open else { return }
+            state = .rolling
+            let generation = nextGeneration()
+            precondition(generation > publishedGeneration, "duplicate generation")
+            publish(generation)
+        }
     }
 
     private func nextGeneration() -> UInt64 {
--- a/Sources/Atlas/SegmentReader.swift
+++ b/Sources/Atlas/SegmentReader.swift
@@ -18,6 +18,9 @@ struct SegmentReader {
     mutating func accept(_ segment: Segment) throws {
+        guard segment.generation > lastGeneration else {
+            throw SegmentError.nonMonotonicGeneration(segment.generation)
+        }
         lastGeneration = segment.generation
     }
