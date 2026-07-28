The guard belongs in the writer, not the caller:

```swift
func rollSegment(reason: RollReason) {
    queue.assertIsolated()
    guard state == .open else { return }
    state = .rolling
    publish(nextGeneration())
}
```

Plain fences with no language carry command text:

```
atlas-index --shards 2 --segment-budget 1024
```

That is the whole change.
