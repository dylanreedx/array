Here is the patch as it arrives, mid-stream:

```swift
func rollSegment(reason: RollReason) {
    queue.assertIsolated()
    guard state == .open else { retu
