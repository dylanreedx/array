import AppKit
import ContinuumRevivedCore
import ImageIO
import UniformTypeIdentifiers

/// Actual file bodies reached through the production boot mount and workspace
/// API. No test-only scene install, parser substitution, application launch or
/// access to a user's project. All fixtures are generated under the API bench.
@MainActor
enum FileFormatsChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(description: message) }
    }
    private static func eventually(_ message: String, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !predicate() {
            guard Date() < deadline else { throw Failure(description: message) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private static func labels(in view: NSView?) -> [String] {
        guard let view else { return [] }
        let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return own + view.subviews.flatMap { labels(in: $0) }
    }

    static func run() async throws {
        _ = NSApplication.shared
        let utf8 = Data("id,value\r\n00123,9007199254740993\r\n".utf8)
        guard let utf16Text = "id\tvalue\r\n00123\t雪\r\n".data(using: .utf16LittleEndian) else {
            throw Failure(description: "UTF-16 fixture encoding failed")
        }
        var utf16 = Data([0xFF, 0xFE]); utf16.append(utf16Text)
        let formats: [(String, Data)] = [
            ("pixels.png", try png()), ("records.csv", utf8),
            ("unicode.tsv", utf16), ("workbook.xlsx", workbook())
        ]
        // A single active document per fixture makes release of its admission
        // leases observable, independently of other previews' shared cache hits.
        for (name, bytes) in formats { try await runDocument(name: name, bytes: bytes) }
    }

    private static func runDocument(name: String, bytes: Data) async throws {
        let budgetBefore = FileContentBudget.shared.retainedBytes
        // The fixture's own markdown text tiles legitimately hold shared
        // observers while mounted; only the document under test must release.
        func documentObservers() -> Int {
            FileContentObservation.shared.qaObserverPaths.filter { !$0.hasSuffix(".md") }.count
        }
        let observationsBefore = documentObservers()
        let f = try WorkspaceAPIChecks.makeFixture()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 2000, height: 1200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = f.canvas
        defer {
            for tile in f.canvas.allWorkspaceTiles() { f.canvas.tileView(for: tile.id)?.prepareForRemovalFromScene() }
            window.contentView = nil
            window.close()
            f.tearDown()
        }
        let url = f.pbRoot.appendingPathComponent(name)
        try bytes.write(to: url)
        let initialRetryCaptured = DispatchSemaphore(value: 0)
        let initialRetryContinue = DispatchSemaphore(value: 0)
        if name.hasSuffix(".csv") {
            FileContentCoordinator.shared.qaFailNextCapture(forPath: url.path)
            FileContentCoordinator.shared.qaAfterCaptureOnce(forPath: url.path) {
                initialRetryCaptured.signal()
                _ = initialRetryContinue.wait(timeout: .now() + 30)
            }
        }
        defer {
            initialRetryContinue.signal()
            FileContentCoordinator.shared.qaClearCaptureFailure(forPath: url.path)
            FileContentCoordinator.shared.qaClearAfterCaptureHook(forPath: url.path)
        }
        try expect(f.runtime.qaHasCanvas, "format fixture bypassed the production mount")
        try expect(f.delegate.qaAgentSupervisor.setWorkspaceToolsEnabled(agentID: f.agentId, true), "workspace tools policy did not enable")
        let armed = f.canvas.armedZoneId
        let viewportApplications = f.canvas.qaViewportApplyCount
        let reply = f.api.dispatch(agentId: f.agentId, requestId: "format-" + name, op: "artifact.open", payload: [
            "relativePath": name, "presentation": ["camera": "preserve"]
        ])
        guard case let .result(result) = reply,
              let rawID = result["tileId"]?.string, let tileID = UUID(uuidString: rawID) else {
            throw Failure(description: "\(name): production artifact.open failed: \(reply)")
        }
        try expect(result["projectId"]?.string == f.projectPb.uuidString, "\(name): opened the armed project instead of the agent checkout")
        try expect(f.canvas.zoneId(containing: tileID) == f.zoneB, "\(name): wrong zone")
        try expect(f.canvas.armedZoneId == armed && f.canvas.qaViewportApplyCount == viewportApplications,
                   "\(name): opening a preview changed the armed zone or camera")
        guard let initial = f.canvas.tileView(for: tileID) as? FileTileNSView else {
            throw Failure(description: "\(name): production open did not mount a file host")
        }
        if name.hasSuffix(".csv") {
            let initialStamp = FileContentObservation.Stamp(path: url.path)
            try await eventually("initial snapshot failure was not shown", {
                initial.qaRenderer == nil && labels(in: initial.qaActiveBody).contains { $0.contains("private file preview") }
            })
            // Detaching cancels work. Reattachment must resume the retry even
            // though the source stamp has not changed.
            window.contentView = nil
            try await Task.sleep(for: .milliseconds(1_300))
            try expect(initial.qaRichNeedsRetry && initialRetryCaptured.wait(timeout: .now()) == .timedOut,
                       "detached tile must retain its retry obligation without running it")
            window.contentView = f.canvas
            try await eventually("initial failure did not retry after reattachment", {
                initialRetryCaptured.wait(timeout: .now()) == .success
            })
            try expect(FileContentObservation.Stamp(path: url.path) == initialStamp,
                       "initial retry fixture must not change the source stamp")
            initialRetryContinue.signal()
            try await eventually("initial failure did not recover", {
                initial.qaRenderer != nil && !initial.qaRichRefreshPending
            })
        }
        try await ready(initial, name: name)
        if let world = result["actualWorldRect"]?.object,
           let x = (world["x"]?.value as? NSNumber)?.doubleValue,
           let y = (world["y"]?.value as? NSNumber)?.doubleValue {
            f.canvas.setViewport(CanvasViewport(x: x - 24, y: y - 24, zoom: 1))
            f.canvas.layoutSubtreeIfNeeded()
        }
        try await checkBody(initial, name: name)
        try capture(initial, name: name)
        let afterOpen = try Data(contentsOf: url)
        try expect(afterOpen == bytes, "\(name): opening a read-only preview wrote source bytes")
        let persisted = try f.storePb.loadCanvas()
        guard let record = persisted.tiles.first(where: { $0.id == tileID }) else {
            throw Failure(description: "\(name): production open did not persist the file tile")
        }
        try expect(record.kind == .file && record.zoneId == f.zoneB, "\(name): preview changed durable tile identity")
        let world = result["actualWorldRect"]?.object
        try expect((world?["x"]?.value as? NSNumber)?.doubleValue == record.frame.x && (world?["y"]?.value as? NSNumber)?.doubleValue == record.frame.y,
                   "\(name): API world coordinates differ from persisted frame")

        // Workspace switch must dispose its mounted body, then hydrate from the
        // same persisted .file record and reconstruct the proper native body.
        try f.runtime.switchWorkspace(to: f.workspaceWB)
        try expect(initial.qaRenderer == nil && !initial.qaRichLoading,
                   "\(name): workspace departure retained a renderer or request")
        try f.runtime.switchWorkspace(to: f.workspaceWA)
        guard let restored = f.canvas.tileView(for: tileID) as? FileTileNSView else {
            throw Failure(description: "\(name): workspace round trip lost the file tile")
        }
        try await ready(restored, name: name)
        try await checkBody(restored, name: name)
        guard let observedPath = restored.tile.metadata.documentLocation?.path ?? restored.tile.metadata.filePath else {
            throw Failure(description: "\(name): restored tile has no observed path")
        }
        try expect(restored.tile.metadata.documentLocation == record.metadata.documentLocation,
                   "\(name): hydration changed document ownership")
        let afterHydration = try Data(contentsOf: url)
        try expect(afterHydration == bytes, "\(name): hydration wrote source bytes")

        if name.hasSuffix(".csv") {
            // Drive the same shared observation clock as the live file tile.
            // Distinct metadata changes arrive as one burst; unchanged bytes
            // must not dispose the renderer, reset its grid, or decode again.
            weak var originalRenderer = restored.qaRenderer
            try expect(originalRenderer != nil, "CSV fixture must start with a live renderer")
            let startsBefore = restored.qaRichRefreshStartCount
            let finishesBefore = restored.qaRichRefreshFinishCount
            FileContentCoordinator.shared.qaBeginDecodeTracking(forPath: url.path)
            defer { FileContentCoordinator.shared.qaEndDecodeTracking(forPath: url.path) }
            func waitForCoordinator(_ message: String) async throws {
                try await eventually(message, {
                    !restored.qaRichRefreshPending
                        && FileContentCoordinator.shared.qaActiveOperationCount(forPath: url.path) == 0
                })
            }
            try await waitForCoordinator("CSV source never reached a quiet baseline")
            let decodesBefore = FileContentCoordinator.shared.qaDecodeCount(forPath: url.path)
            for offset in 0..<3 {
                try FileManager.default.setAttributes(
                    [.modificationDate: Date(timeIntervalSince1970: 1_900_000_000 + Double(offset))],
                    ofItemAtPath: url.path)
                FileContentObservation.shared.poll()
            }
            let replacedImmediately = originalRenderer == nil || restored.qaRenderer !== originalRenderer
            print("rich file metadata burst before wait: \(restored.qaRichRefreshStartCount - startsBefore) refresh starts, \(replacedImmediately ? 1 : 0) renderer replacements, \(FileContentCoordinator.shared.qaDecodeCount(forPath: url.path) - decodesBefore) decoder starts")
            try expect(!replacedImmediately,
                       "a metadata change must retain the renderer while checking content")
            try await eventually("metadata-only burst did not complete its refresh", {
                restored.qaRichRefreshFinishCount > finishesBefore && !restored.qaRichRefreshPending
            })
            try expect(restored.qaRichRefreshStartCount - startsBefore == 1,
                       "a burst of unchanged-file observations must coalesce into one refresh")
            try expect(originalRenderer != nil && restored.qaRenderer === originalRenderer,
                       "metadata-only changes with identical bytes must retain the actual rich renderer")
            let additionalDecodes = FileContentCoordinator.shared.qaDecodeCount(forPath: url.path) - decodesBefore
            try expect(additionalDecodes == 0, "metadata-only changes with identical bytes must not decode again")
            print("rich file metadata burst: \(restored.qaRichRefreshStartCount - startsBefore) refresh, 0 renderer replacements and \(additionalDecodes) decodes across 3 observations")
            try await selectedValue(restored, expected: "00123")

            // Same-sized different bytes must not be confused with identical
            // content, even though the existing renderer was kept during I/O.
            let replacement = Data("id,value\r\n00999,9007199254740993\r\n".utf8)
            try expect(replacement.count == bytes.count, "changed CSV fixture must keep the original byte count")
            let changedFinish = restored.qaRichRefreshFinishCount
            let changedDecodes = FileContentCoordinator.shared.qaDecodeCount(forPath: url.path)
            try replacement.write(to: url, options: .atomic)
            FileContentObservation.shared.poll()
            try await eventually("same-size changed CSV did not finish refresh", {
                restored.qaRichRefreshFinishCount > changedFinish && !restored.qaRichRefreshPending
            })
            try await ready(restored, name: name)
            try expect(restored.qaRenderer !== originalRenderer,
                       "changed CSV bytes must replace the old renderer")
            try expect(FileContentCoordinator.shared.qaDecodeCount(forPath: url.path) > changedDecodes,
                       "changed CSV bytes must start an actual decode")
            try await selectedValue(restored, expected: "00999")
            try await waitForCoordinator("changed CSV worker did not finish")

            // Hold the worker after it captures the first valid immutable copy,
            // then replace the source again before the worker resumes. The real
            // observer sees the later write while a refresh is in flight.
            let captured = DispatchSemaphore(value: 0)
            let resumeCapture = DispatchSemaphore(value: 0)
            FileContentCoordinator.shared.qaAfterCaptureOnce(forPath: url.path) {
                captured.signal()
                _ = resumeCapture.wait(timeout: .now() + 30)
            }
            defer {
                resumeCapture.signal()
                FileContentCoordinator.shared.qaClearAfterCaptureHook(forPath: url.path)
            }
            let firstInFlight = Data("id,value\r\n00888,9007199254740993\r\n".utf8)
            let finalInFlight = Data("id,value\r\n00777,9007199254740993\r\n".utf8)
            let inFlightFinish = restored.qaRichRefreshFinishCount
            try firstInFlight.write(to: url, options: .atomic)
            FileContentObservation.shared.poll()
            try await eventually("in-flight refresh did not reach the capture barrier", {
                captured.wait(timeout: .now()) == .success
            })
            try finalInFlight.write(to: url, options: .atomic)
            FileContentObservation.shared.poll()
            resumeCapture.signal()
            try await eventually("write during capture did not settle", {
                restored.qaRichRefreshFinishCount > inFlightFinish && !restored.qaRichRefreshPending
                    && restored.qaRenderer != nil
            })
            try await selectedValue(restored, expected: "00777")
            try await waitForCoordinator("in-flight CSV workers did not finish")

            // A same-inode, same-size write can restore the same mtime while a
            // captured snapshot is blocked. The ctime change must trigger a
            // retry so the later bytes, not the captured old bytes, appear.
            let inPlaceCaptured = DispatchSemaphore(value: 0)
            let resumeInPlace = DispatchSemaphore(value: 0)
            FileContentCoordinator.shared.qaAfterCaptureOnce(forPath: url.path) {
                inPlaceCaptured.signal()
                _ = resumeInPlace.wait(timeout: .now() + 30)
            }
            defer {
                resumeInPlace.signal()
                FileContentCoordinator.shared.qaClearAfterCaptureHook(forPath: url.path)
            }
            let inPlaceDate = Date(timeIntervalSince1970: 1_900_000_800)
            try FileManager.default.setAttributes([.modificationDate: inPlaceDate], ofItemAtPath: url.path)
            let beforeInPlace = FileContentObservation.Stamp(path: url.path)
            let inPlaceFinish = restored.qaRichRefreshFinishCount
            FileContentObservation.shared.poll()
            try await eventually("in-place refresh did not reach the capture barrier", {
                inPlaceCaptured.wait(timeout: .now()) == .success
            })
            let suppressedBefore = FileContentObservation.shared.qaSuppressedCallbackCount(forPath: observedPath)
            FileContentObservation.shared.qaSetCallbacksSuppressed(forPath: observedPath, suppressed: true)
            defer { FileContentObservation.shared.qaSetCallbacksSuppressed(forPath: observedPath, suppressed: false) }
            let inPlaceBytes = Data("id,value\r\n00555,9007199254740993\r\n".utf8)
            try expect(inPlaceBytes.count == finalInFlight.count, "in-place rewrite must retain byte count")
            let handle = try FileHandle(forWritingTo: url)
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: inPlaceBytes)
            try handle.close()
            try FileManager.default.setAttributes([.modificationDate: inPlaceDate], ofItemAtPath: url.path)
            let afterInPlace = FileContentObservation.Stamp(path: url.path)
            try expect(beforeInPlace.device == afterInPlace.device && beforeInPlace.inode == afterInPlace.inode
                       && beforeInPlace.bytes == afterInPlace.bytes
                       && beforeInPlace.modifiedSeconds == afterInPlace.modifiedSeconds
                       && beforeInPlace.modifiedNanoseconds == afterInPlace.modifiedNanoseconds
                       && (beforeInPlace.changedSeconds != afterInPlace.changedSeconds
                           || beforeInPlace.changedNanoseconds != afterInPlace.changedNanoseconds),
                       "in-place fixture must preserve device, inode, size and mtime while changing ctime")
            // Advance the observer's stamp without delivering its callback:
            // completion must independently detect the changed source.
            FileContentObservation.shared.poll()
            try expect(FileContentObservation.shared.qaSuppressedCallbackCount(forPath: observedPath) > suppressedBefore,
                       "the in-flight fixture must suppress a real observer callback")
            resumeInPlace.signal()
            try await eventually("in-place write during capture did not settle", {
                restored.qaRichRefreshFinishCount > inPlaceFinish && !restored.qaRichRefreshPending
                    && restored.qaRenderer != nil
            })
            try await selectedValue(restored, expected: "00555")
            FileContentObservation.shared.qaSetCallbacksSuppressed(forPath: observedPath, suppressed: false)
            try await waitForCoordinator("in-place CSV workers did not finish")

            // An unchanged-stamp transient snapshot failure must display a
            // failure and retry on its own; no second file event is supplied.
            let retryCaptured = DispatchSemaphore(value: 0)
            let resumeRetry = DispatchSemaphore(value: 0)
            FileContentCoordinator.shared.qaFailNextCapture(forPath: url.path)
            FileContentCoordinator.shared.qaAfterCaptureOnce(forPath: url.path) {
                retryCaptured.signal()
                _ = resumeRetry.wait(timeout: .now() + 30)
            }
            defer {
                resumeRetry.signal()
                FileContentCoordinator.shared.qaClearCaptureFailure(forPath: url.path)
                FileContentCoordinator.shared.qaClearAfterCaptureHook(forPath: url.path)
            }
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_900_001_000)], ofItemAtPath: url.path)
            let transientStamp = FileContentObservation.Stamp(path: url.path)
            let transientFinish = restored.qaRichRefreshFinishCount
            FileContentObservation.shared.poll()
            try await eventually("transient snapshot failure was not shown", {
                restored.qaRichRefreshFinishCount > transientFinish && restored.qaRenderer == nil
                    && labels(in: restored.qaActiveBody).contains { $0.contains("private file preview") }
            })
            let transientBody = restored.qaActiveBody
            let firstFailureFinish = restored.qaRichRefreshFinishCount
            window.contentView = nil
            try await Task.sleep(for: .milliseconds(1_300))
            try expect(restored.qaRichNeedsRetry && retryCaptured.wait(timeout: .now()) == .timedOut,
                       "detached tile must keep its retry obligation without running it")
            FileContentCoordinator.shared.qaFailNextCapture(forPath: url.path)
            window.contentView = f.canvas
            try await eventually("repeated identical snapshot failure was not retried", {
                restored.qaRichRefreshFinishCount > firstFailureFinish && restored.qaRenderer == nil
            })
            try expect(restored.qaActiveBody === transientBody,
                       "repeating the same snapshot failure must retain its visible error body")
            try await eventually("unchanged-stamp snapshot failure did not retry after reattachment", {
                retryCaptured.wait(timeout: .now()) == .success
            })
            try expect(FileContentObservation.Stamp(path: url.path) == transientStamp,
                       "transient recovery fixture must not modify the source again")
            resumeRetry.signal()
            try await eventually("transient snapshot failure did not recover", {
                restored.qaRenderer != nil && !restored.qaRichRefreshPending
            })
            try await selectedValue(restored, expected: "00555")
            try await waitForCoordinator("transient retry worker did not finish")

            // Comparing valid private snapshots can fail independently of
            // capture. It too must retry with no further filesystem event.
            FileContentCoordinator.shared.qaFailNextComparison(forPath: url.path)
            defer { FileContentCoordinator.shared.qaClearComparisonFailure(forPath: url.path) }
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_900_001_100)], ofItemAtPath: url.path)
            let comparisonStamp = FileContentObservation.Stamp(path: url.path)
            let comparisonFinish = restored.qaRichRefreshFinishCount
            FileContentObservation.shared.poll()
            try await eventually("snapshot comparison failure was not shown", {
                restored.qaRichRefreshFinishCount > comparisonFinish && restored.qaRenderer == nil
                    && labels(in: restored.qaActiveBody).contains { $0.contains("compare its private snapshots") }
            })
            try await eventually("snapshot comparison failure did not retry", {
                restored.qaRenderer != nil && !restored.qaRichRefreshPending
            })
            try expect(FileContentObservation.Stamp(path: url.path) == comparisonStamp,
                       "snapshot comparison recovery must not require another source change")
            try await selectedValue(restored, expected: "00555")
            try await waitForCoordinator("comparison retry worker did not finish")

            // Exhaust the real preview budget before changing bytes. Detach
            // during the bounded 100 ms retry, before terminal failure; after
            // pressure clears, the same stamp must recover on reattachment.
            let budget = FileContentBudget.shared
            var pressureLease: FileContentBudget.Lease? = try budget.reserve(budget.limit - budget.retainedBytes)
            defer { pressureLease = nil }
            let budgetReplacement = Data("id,value\r\n00666,9007199254740993\r\n".utf8)
            let budgetStarts = restored.qaRichRefreshStartCount
            var budgetRetryHooks = 0
            var budgetRetryWasPending = false
            restored.qaDidScheduleRichBudgetRetry = {
                budgetRetryHooks += 1
                budgetRetryWasPending = restored.qaRichRefreshStartCount > budgetStarts
                    && restored.qaRenderer == nil && restored.qaRichRefreshPending && restored.qaRichNeedsRetry
                restored.qaDidScheduleRichBudgetRetry = nil
                window.contentView = nil
            }
            defer { restored.qaDidScheduleRichBudgetRetry = nil }
            try budgetReplacement.write(to: url, options: .atomic)
            let budgetStamp = FileContentObservation.Stamp(path: url.path)
            FileContentObservation.shared.poll()
            try await eventually("budget pressure never entered its pending retry", {
                budgetRetryHooks > 0
            })
            try expect(budgetRetryWasPending,
                       "budget hook must run during the scheduled retry before terminal failure")
            let startsAtDetach = restored.qaRichRefreshStartCount
            pressureLease = nil
            try await eventually("canceled budget worker did not drain", {
                FileContentCoordinator.shared.qaActiveOperationCount(forPath: url.path) == 0
            })
            try await Task.sleep(for: .milliseconds(1_300))
            try expect(restored.qaRenderer == nil && restored.qaRichNeedsRetry
                       && restored.qaRichRefreshStartCount == startsAtDetach,
                       "detached tile must retain retry state without restarting work")
            window.contentView = f.canvas
            try await eventually("detached preview budget retry did not recover", {
                restored.qaRenderer != nil && !restored.qaRichRefreshPending
            })
            try expect(FileContentObservation.Stamp(path: url.path) == budgetStamp,
                       "budget recovery fixture must not modify the source again")
            try await selectedValue(restored, expected: "00666")

            // Missing and recreated content are real state changes, not an
            // excuse to retain stale pixels or stop observing the path.
            let deletionFinish = restored.qaRichRefreshFinishCount
            try FileManager.default.removeItem(at: url)
            FileContentObservation.shared.poll()
            try await eventually("deleted CSV did not finish refresh", {
                restored.qaRichRefreshFinishCount > deletionFinish && !restored.qaRichRefreshPending
            })
            try expect(restored.qaRenderer == nil && !restored.qaHasDocumentSession,
                       "deleted CSV must remove its stale renderer")
            let recreationFinish = restored.qaRichRefreshFinishCount
            try replacement.write(to: url, options: .atomic)
            FileContentObservation.shared.poll()
            try await eventually("recreated CSV did not finish refresh", {
                restored.qaRichRefreshFinishCount > recreationFinish && !restored.qaRichRefreshPending
            })
            try await ready(restored, name: name)
            try await selectedValue(restored, expected: "00999")

            // Drive the same filesystem coordinator and notification the real
            // file-tree rename sends. Never present a modal or touch Trash.
            let moved = try ProjectFileOperationCoordinator(rootURL: f.pbRoot).rename(entry: url, newName: "renamed.csv")
            NotificationCenter.default.post(name: .arrayProjectFileMoved, object: nil,
                userInfo: ["source": moved.source.path, "destination": moved.destination.path, "directory": false])
            try await ready(restored, name: "renamed.csv")
            if initial !== restored {
                try expect(initial.qaRenderer == nil && !initial.qaRichLoading, "rename resurrected a retired preview host")
            }
            try expect(restored.tile.metadata.documentLocation?.path == moved.destination.path,
                       "rename did not update rich document identity")
            try await selectedValue(restored, expected: "00999")
            let renamedDeletionFinish = restored.qaRichRefreshFinishCount
            try FileManager.default.removeItem(at: moved.destination)
            FileContentObservation.shared.poll()
            try await eventually("deleted source did not finish its failed load", {
                restored.qaRichRefreshFinishCount > renamedDeletionFinish && !restored.qaRichRefreshPending
            })
            try expect(restored.qaRenderer == nil && !restored.qaHasDocumentSession,
                       "deleted source left a stale renderer or created a text session")
        }
        f.canvas.removeTile(id: tileID)
        try expect(restored.qaRenderer == nil && !restored.qaRichLoading, "\(name): tile removal retained a renderer")
        do {
            try await eventually("\(name): file resources or observers were not released", {
                FileContentBudget.shared.retainedBytes == budgetBefore && documentObservers() == observationsBefore
            })
        } catch {
            let work = await FileGridWorkScheduler.shared.qaCounts
            throw Failure(description: "\(name): resources: budget \(FileContentBudget.shared.retainedBytes)/\(budgetBefore), observers \(documentObservers())/\(observationsBefore), retiredRendererAlive=\(restored.qaRetiredRendererAlive), workers=\(work)")
        }
    }

    private static func ready(_ host: FileTileNSView, name: String) async throws {
        try await eventually("\(name): rich preview did not finish", { !host.qaRichLoading })
        try expect(host.qaRenderer != nil, "\(name): completed without a supported native body")
        try expect(!host.qaHasDocumentSession && host.loadedText == nil && !host.isDirty,
                   "\(name): read-only preview allocated an editing session or draft")
        guard let body = host.qaRenderer?.view else { return }
        try expect(body.superview != nil && body.window != nil, "\(name): renderer was constructed but never mounted")
        host.layoutSubtreeIfNeeded()
    }
    private static func checkBody(_ host: FileTileNSView, name: String) async throws {
        if name.hasSuffix(".png") {
            guard let image = host.qaRenderer as? FileImageRenderer else { throw Failure(description: "PNG did not mount ImageIO renderer") }
            try expect(image.qaViewport.document != nil, "mounted image has no decoded pixels")
        } else if name.hasSuffix(".xlsx") {
            guard let workbook = host.qaRenderer as? WorkbookGridRenderer else { throw Failure(description: "XLSX did not mount workbook renderer") }
            try expect(workbook.workbook?.visibleSheets.count == 1 && workbook.qaSelectedSheet == "0", "workbook sheet selection lost")
            try await selectedValue(host, expected: "00123")
        } else {
            try expect(host.qaRenderer is DelimitedGridRenderer, "\(name): no delimited grid")
            try await selectedValue(host, expected: "00123")
            if name.hasSuffix(".tsv"), let grid = host.qaRenderer as? DelimitedGridRenderer {
                grid.qaSelect(row: 1, column: 1)
                try await eventually("UTF-16 cell projection did not load", { !grid.qaIsLoading })
                grid.qaSelect(row: 1, column: 1)
                try expect(grid.qaSelectedValue == "雪", "UTF-16 TSV projection lost Unicode")
            }
        }
    }
    private static func selectedValue(_ host: FileTileNSView, expected: String) async throws {
        let grid = (host.qaRenderer as? DelimitedGridRenderer) ?? (host.qaRenderer as? WorkbookGridRenderer)?.qaGrid
        guard let grid else { throw Failure(description: "no grid to inspect selection") }
        grid.setVisible(true)
        grid.qaLayout(size: NSSize(width: 700, height: 420))
        try await eventually("grid projected pages did not complete", { !grid.qaIsLoading })
        grid.qaSelect(row: 1, column: 0)
        try await eventually("selected cell page did not complete", { !grid.qaIsLoading })
        grid.qaSelect(row: 1, column: 0)
        try expect(grid.qaSelectedValue == expected, "mounted grid changed exact cell text: \(String(describing: grid.qaSelectedValue))")
        try expect(grid.qaCachedPageCount <= 8 && grid.qaCachedBytes <= 4 * 1_024 * 1_024, "mounted grid exceeded page bounds")
    }

    private static func capture(_ host: FileTileNSView, name: String) throws {
        guard let body = host.qaRenderer?.view else { return }
        // Capture the complete body in a fixed QA window. The production canvas
        // clips offscreen content; caching a larger rect there can hide controls.
        guard let parent = body.superview else { throw Failure(description: "unmounted capture body") }
        let constraints = parent.constraints.filter { ($0.firstItem as? NSView) === body || ($0.secondItem as? NSView) === body }
        let originalFrame = body.frame
        let translates = body.translatesAutoresizingMaskIntoConstraints
        let originalMask = body.autoresizingMask
        NSLayoutConstraint.deactivate(constraints)
        body.removeFromSuperview()
        let preview = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        preview.isReleasedWhenClosed = false
        body.translatesAutoresizingMaskIntoConstraints = true
        let backingHost = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 460))
        backingHost.wantsLayer = true
        preview.contentView = backingHost
        body.frame = backingHost.bounds
        body.autoresizingMask = [.width, .height]
        backingHost.addSubview(body)
        defer {
            preview.contentView = nil
            preview.close()
            body.removeFromSuperview()
            body.autoresizingMask = originalMask
            body.translatesAutoresizingMaskIntoConstraints = translates
            parent.addSubview(body)
            body.frame = originalFrame
            NSLayoutConstraint.activate(constraints)
            host.layoutSubtreeIfNeeded()
        }
        let root = ProcessInfo.processInfo.environment["ARRAY_FILE_APPEARANCE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let root { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            body.appearance = NSAppearance(named: appearance)
            host.qaRenderer?.applyTheme()
            body.setFrameSize(NSSize(width: 760, height: 460))
            body.needsLayout = true
            body.layoutSubtreeIfNeeded()
            for child in body.subviews where !child.isHidden {
                try expect(body.bounds.intersects(child.frame), "visible renderer control is outside its body: \(type(of: child)) \(child.frame) in \(body.bounds)")
            }
            preview.appearance = body.appearance
            var rendered: Result<NSBitmapImageRep, Error> = .failure(Failure(description: "appearance did not render"))
            body.effectiveAppearance.performAsCurrentDrawingAppearance {
                rendered = Result { try UIProbe.bitmap(of: body, id: "file-format-" + name + "-" + suffix) }
            }
            let bitmap = try rendered.get()
            if let root, let encoded = bitmap.representation(using: .png, properties: [:]) {
                try encoded.write(to: root.appendingPathComponent(name + "-" + suffix + ".png"))
            }
            // Toolbar glyphs, and the image footer, must survive sibling drawing
            // in both themes. Data inspectors may have legitimate blank bottoms.
            guard let pixels = bitmap.bitmapData else { throw Failure(description: "missing bitmap pixels") }
            let bytesPerPixel = bitmap.bitsPerPixel / 8
            let edgeRows = name.hasSuffix(".png") ? [0, max(0, bitmap.pixelsHigh - 64)] : [0]
            for firstRow in edgeRows {
                var colours = Set<UInt32>()
                for y in firstRow..<min(firstRow + 64, bitmap.pixelsHigh) {
                    for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                        let offset = y * bitmap.bytesPerRow + x * bytesPerPixel
                        colours.insert(UInt32(pixels[offset]) << 16 | UInt32(pixels[offset + 1]) << 8 | UInt32(pixels[offset + 2]))
                    }
                }
                try expect(colours.count > 8, "\(name) \(suffix): content drawing covered toolbar or inspector (\(colours.count) edge colours at row \(firstRow))")
            }

        }
        body.appearance = nil
        host.qaRenderer?.applyTheme()
    }
    private static func png() throws -> Data {
        let pixels = Data([255, 0, 0, 255, 0, 0, 255, 255])
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw Failure(description: "cannot create PNG fixture pixels")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure(description: "cannot create PNG fixture encoder")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure(description: "PNG fixture encoding failed") }
        return data as Data
    }
    private static func workbook() -> Data {
        storedZIP([
            ("xl/workbook.xml", "<workbook xmlns:r=\"urn:relationships\"><sheets><sheet name=\"Values\" r:id=\"r1\"/></sheets></workbook>"),
            ("xl/_rels/workbook.xml.rels", "<Relationships><Relationship Id=\"r1\" Target=\"worksheets/sheet1.xml\"/></Relationships>"),
            ("xl/worksheets/sheet1.xml", "<worksheet><sheetData><row><c r=\"A1\" t=\"inlineStr\"><is><t>id</t></is></c></row><row><c r=\"A2\" t=\"inlineStr\"><is><t>00123</t></is></c></row></sheetData></worksheet>")
        ])
    }
    /// Stored ZIP records include the complete 46-byte central-directory header;
    /// lengths and offsets are computed from the bytes actually appended.
    private static func storedZIP(_ files: [(String, String)]) -> Data {
        var output = Data(), central = Data()
        func u16(_ value: Int) -> Data { var v = UInt16(value).littleEndian; return withUnsafeBytes(of: &v) { Data($0) } }
        func u32(_ value: UInt32) -> Data { var v = value.littleEndian; return withUnsafeBytes(of: &v) { Data($0) } }
        func crc(_ bytes: Data) -> UInt32 {
            var value: UInt32 = 0xFFFFFFFF
            for byte in bytes { value ^= UInt32(byte); for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 1 ? 0xEDB88320 : 0) } }
            return value ^ 0xFFFFFFFF
        }
        for (path, text) in files {
            let name = Data(path.utf8), bytes = Data(text.utf8), offset = output.count, checksum = crc(bytes)
            let local: [Data] = [u32(0x04034B50), u16(20), u16(0), u16(0), u16(0), u16(0), u32(checksum), u32(UInt32(bytes.count)), u32(UInt32(bytes.count)), u16(name.count), u16(0), name, bytes]
            for part in local { output.append(part) }
            let record: [Data] = [u32(0x02014B50), u16(20), u16(20), u16(0), u16(0), u16(0), u16(0), u32(checksum), u32(UInt32(bytes.count)), u32(UInt32(bytes.count)), u16(name.count), u16(0), u16(0), u16(0), u16(0), u32(0), u32(UInt32(offset)), name]
            for part in record { central.append(part) }
        }
        let offset = output.count
        output.append(central)
        let end: [Data] = [u32(0x06054B50), u16(0), u16(0), u16(files.count), u16(files.count), u32(UInt32(central.count)), u32(UInt32(offset)), u16(0)]
        for part in end { output.append(part) }
        return output
    }
}
