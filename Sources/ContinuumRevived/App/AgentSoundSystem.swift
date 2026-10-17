import AppKit
import AVFoundation
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation
import UniformTypeIdentifiers

extension Notification.Name {
    static let agentSignalDidChange = Notification.Name("continuum.agentSignalDidChange")
    static let agentSoundLibraryDidChange = Notification.Name("continuum.agentSoundLibraryDidChange")
}

@MainActor
final class AgentSoundLibrary {
    static let shared = AgentSoundLibrary()

    enum LibraryError: LocalizedError {
        case unsupported
        case tooLarge
        case tooLong
        case bundledManifestMissing

        var errorDescription: String? {
            switch self {
            case .unsupported: return "Array could not decode this audio file."
            case .tooLarge: return "Agent sounds must be 20 MB or smaller."
            case .tooLong: return "Agent sounds must be 10 seconds or shorter."
            case .bundledManifestMissing: return "The bundled sound manifest is missing."
            }
        }
    }

    private let fileManager: FileManager
    private let bundleRoot: URL
    private let importedRoot: URL
    private let importedManifestURL: URL
    private(set) var bundledEntries: [AgentSoundManifestEntry] = []
    private(set) var importedEntries: [AgentSoundManifestEntry] = []

    var allEntries: [AgentSoundManifestEntry] { bundledEntries + importedEntries }
    var availableReferences: Set<AgentSoundReference> { Set(allEntries.map(\.id)) }

    init(fileManager: FileManager = .default, bundleRoot: URL? = nil, applicationSupportRoot: URL? = nil) {
        self.fileManager = fileManager
        let sourceFallback = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Resources/AgentSounds", isDirectory: true)
        if let bundleRoot {
            self.bundleRoot = bundleRoot
        } else if let bundled = Bundle.main.resourceURL?.appendingPathComponent("AgentSounds", isDirectory: true),
                  fileManager.fileExists(atPath: bundled.appendingPathComponent("manifest.json").path) {
            self.bundleRoot = bundled
        } else {
            self.bundleRoot = sourceFallback
        }
        let support = applicationSupportRoot ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppChannel.liveApplicationSupportDirectoryName, isDirectory: true)
        self.importedRoot = support.appendingPathComponent("AgentSounds/Imported", isDirectory: true)
        self.importedManifestURL = self.importedRoot.appendingPathComponent("manifest.json")
        reload()
    }

    func reload() {
        bundledEntries = decodeManifest(at: bundleRoot.appendingPathComponent("manifest.json"))
        importedEntries = decodeManifest(at: importedManifestURL).filter {
            fileManager.fileExists(atPath: importedRoot.appendingPathComponent($0.filename).path)
        }
    }

    func url(for reference: AgentSoundReference) -> URL? {
        if let entry = bundledEntries.first(where: { $0.id == reference }) {
            let url = bundleRoot.appendingPathComponent(entry.filename)
            return fileManager.fileExists(atPath: url.path) ? url : nil
        }
        if let entry = importedEntries.first(where: { $0.id == reference }) {
            let url = importedRoot.appendingPathComponent(entry.filename)
            return fileManager.fileExists(atPath: url.path) ? url : nil
        }
        return nil
    }

    @discardableResult
    func importSound(from source: URL) throws -> AgentSoundManifestEntry {
        let supported = Set(["wav", "wave", "aif", "aiff", "caf", "m4a", "mp3"])
        guard supported.contains(source.pathExtension.lowercased()) else { throw LibraryError.unsupported }
        let resourceValues = try source.resourceValues(forKeys: [.fileSizeKey])
        guard (resourceValues.fileSize ?? 0) <= 20 * 1_024 * 1_024 else { throw LibraryError.tooLarge }
        let audio: AVAudioFile
        do { audio = try AVAudioFile(forReading: source) } catch { throw LibraryError.unsupported }
        let duration = Double(audio.length) / audio.processingFormat.sampleRate
        guard duration.isFinite, duration > 0 else { throw LibraryError.unsupported }
        guard duration <= 10 else { throw LibraryError.tooLong }

        try fileManager.createDirectory(at: importedRoot, withIntermediateDirectories: true)
        let uuid = UUID()
        let ext = source.pathExtension.isEmpty ? "audio" : source.pathExtension.lowercased()
        let filename = "\(uuid.uuidString.lowercased()).\(ext)"
        try fileManager.copyItem(at: source, to: importedRoot.appendingPathComponent(filename))
        let entry = AgentSoundManifestEntry(
            id: AgentSoundReference(rawValue: "imported.\(uuid.uuidString.lowercased())"),
            name: source.deletingPathExtension().lastPathComponent,
            family: "imported",
            filename: filename,
            duration: duration,
            imported: true)
        importedEntries.append(entry)
        try persistImportedManifest()
        NotificationCenter.default.post(name: .agentSoundLibraryDidChange, object: self)
        return entry
    }

    func rename(_ reference: AgentSoundReference, to proposedName: String) throws {
        guard let index = importedEntries.firstIndex(where: { $0.id == reference }) else { return }
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        importedEntries[index].name = String(name.prefix(80))
        try persistImportedManifest()
        NotificationCenter.default.post(name: .agentSoundLibraryDidChange, object: self)
    }

    func remove(_ reference: AgentSoundReference) throws {
        guard let index = importedEntries.firstIndex(where: { $0.id == reference }) else { return }
        let entry = importedEntries.remove(at: index)
        try fileManager.removeItem(at: importedRoot.appendingPathComponent(entry.filename))
        try persistImportedManifest()
        NotificationCenter.default.post(name: .agentSoundLibraryDidChange, object: self)
    }

    private func decodeManifest(at url: URL) -> [AgentSoundManifestEntry] {
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([AgentSoundManifestEntry].self, from: data) else { return [] }
        return entries
    }

    private func persistImportedManifest() throws {
        try fileManager.createDirectory(at: importedRoot, withIntermediateDirectories: true)
        let data = try JSONEncoder.pretty.encode(importedEntries)
        try data.write(to: importedManifestURL, options: .atomic)
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

/// What `AgentSignalCenter` plays through — the shipped `AgentSoundPlayer`, or a
/// recorder in a witness that must hear exactly what a person would.
@MainActor
protocol AgentSoundPlaying: AnyObject {
    func play(_ reference: AgentSoundReference, priority: Int, volume: Double, library: AgentSoundLibrary)
}

@MainActor
final class AgentSoundPlayer: NSObject, AVAudioPlayerDelegate, AgentSoundPlaying {
    static let shared = AgentSoundPlayer()
    private var player: AVAudioPlayer?
    private var currentPriority = 0

    func play(_ reference: AgentSoundReference, priority: Int, volume: Double,
              library: AgentSoundLibrary = .shared) {
        guard let url = library.url(for: reference) else { return }
        #if ARRAY_FILM
        // Film build only: a film records the sound for the edit and never plays it.
        if let film = FilmPanelHost.sound { film(reference, priority); return }
        #endif
        if let player, player.isPlaying, priority < currentPriority { return }
        player?.stop()
        do {
            let next = try AVAudioPlayer(contentsOf: url)
            next.volume = Float(min(1, max(0, volume)))
            next.delegate = self
            next.prepareToPlay()
            next.play()
            player = next
            currentPriority = priority
        } catch {
            fputs("Agent sound preview failed: \(error.localizedDescription)\n", stderr)
        }
    }

    func preview(_ reference: AgentSoundReference, library: AgentSoundLibrary = .shared) {
        play(reference, priority: Int.max, volume: AgentSoundConfig.resolvedVolume(), library: library)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.currentPriority = 0 }
    }
}

@MainActor
final class AgentSignalCenter {
    private var reducer = AgentSignalReducer()
    private(set) var currentByTile: [UUID: AgentSignal] = [:]
    private(set) var history: [AgentSignal] = []
    private let defaults: UserDefaults
    private let library: AgentSoundLibrary
    private let player: any AgentSoundPlaying
    var onChanged: ((UUID?) -> Void)?
    #if ARRAY_FILM
    /// Film build only (set by `FilmDirector`, nil otherwise): a transient badge's
    /// 3 s runs on the film clock, so "Pushed" clears 3 s of FILM time later.
    static var filmDelay: ((TimeInterval) async -> Void)?
    #endif

    init(defaults: UserDefaults = .standard, library: AgentSoundLibrary = .shared,
         player: any AgentSoundPlaying = AgentSoundPlayer.shared) {
        self.defaults = defaults
        self.library = library
        self.player = player
    }

    @discardableResult
    func ingest(event: AgentRuntimeEvent, agentID: AgentID?, tileID: UUID?,
                overrides: AgentSoundOverrides? = nil, at now: Date = Date()) -> AgentSignal? {
        if case .turnStarted = event { clearSettledSignal(for: tileID) }
        if case .requestResolved = event { clearActionSignal(for: tileID) }
        if case .userInputResolved = event { clearActionSignal(for: tileID) }
        guard let signal = reducer.ingest(event: event, agentID: agentID, tileID: tileID, at: now) else { return nil }
        publish(signal, overrides: overrides)
        return signal
    }

    @discardableResult
    func ingestObserved(status: AgentStatus, tileID: UUID, overrides: AgentSoundOverrides? = nil,
                        at now: Date = Date()) -> AgentSignal? {
        guard let signal = reducer.ingestObservedStatus(status, tileID: tileID, at: now) else { return nil }
        publish(signal, overrides: overrides)
        return signal
    }

    /// WS4 · the live half of a WATCHED COMPLETION, and deliberately narrower
    /// than `markViewed`.
    ///
    /// `markViewed` is a deliberate human visit and clears failure too. This runs
    /// automatically the moment a completion lands in front of someone, so it may
    /// only ever retire an ordinary success: a failure or an action request that
    /// happens to be current keeps its stronger treatment, and returning false
    /// tells the caller no acknowledgment is owed.
    @discardableResult
    func acknowledgeWatchedCompletion(tileID: UUID) -> Bool {
        guard currentByTile[tileID]?.kind == .completed else { return false }
        currentByTile.removeValue(forKey: tileID)
        qaAcknowledgedCompletionCount += 1
        notify(tileID: tileID)
        return true
    }

    /// Completions retired by `acknowledgeWatchedCompletion`. The positive control
    /// for "the live signal really was cleared here, not merely absent".
    private(set) var qaAcknowledgedCompletionCount = 0

    func markViewed(tileID: UUID) {
        guard let current = currentByTile[tileID], current.kind != .actionRequired else { return }
        currentByTile.removeValue(forKey: tileID)
        notify(tileID: tileID)
    }

    private func publish(_ signal: AgentSignal, overrides: AgentSoundOverrides?) {
        history.append(signal)
        if history.count > 500 { history.removeFirst(history.count - 500) }
        if let tileID = signal.tileID {
            let current = currentByTile[tileID]
            let becomesCurrent = current == nil || signal.kind.priority >= current!.kind.priority
            if becomesCurrent { currentByTile[tileID] = signal }
            if becomesCurrent && !signal.isPersistent {
                Task { @MainActor [weak self] in
                    #if ARRAY_FILM
                    if let filmDelay = Self.filmDelay {
                        await filmDelay(AgentSignalReducer.transientVisualDuration)
                    } else {
                        try? await Task.sleep(for: .seconds(AgentSignalReducer.transientVisualDuration))
                    }
                    #else
                    try? await Task.sleep(for: .seconds(AgentSignalReducer.transientVisualDuration))
                    #endif
                    guard self?.currentByTile[tileID]?.id == signal.id else { return }
                    self?.currentByTile.removeValue(forKey: tileID)
                    self?.notify(tileID: tileID)
                }
            }
        }
        if let sound = AgentSoundConfig.resolvedSound(
            for: signal.kind, tileOverrides: overrides,
            available: library.availableReferences, defaults: defaults) {
            player.play(sound, priority: signal.kind.priority,
                        volume: AgentSoundConfig.resolvedVolume(defaults: defaults), library: library)
        }
        notify(tileID: signal.tileID)
    }

    private func clearSettledSignal(for tileID: UUID?) {
        guard let tileID, let current = currentByTile[tileID], [.completed, .failed].contains(current.kind) else { return }
        currentByTile.removeValue(forKey: tileID)
        notify(tileID: tileID)
    }

    private func clearActionSignal(for tileID: UUID?) {
        guard let tileID, currentByTile[tileID]?.kind == .actionRequired else { return }
        currentByTile.removeValue(forKey: tileID)
        notify(tileID: tileID)
    }

    private func notify(tileID: UUID?) {
        onChanged?(tileID)
        NotificationCenter.default.post(
            name: .agentSignalDidChange, object: self,
            userInfo: tileID.map { ["tileID": $0] } ?? [:])
    }
}

@MainActor
enum AgentAwarenessSelfCheck {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func run() throws {
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw Failure(description: message) }
        }
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("array-agent-awareness-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temporary) }
        let bundled = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Resources/AgentSounds", isDirectory: true)
        let support = temporary.appendingPathComponent("support", isDirectory: true)
        let library = AgentSoundLibrary(bundleRoot: bundled, applicationSupportRoot: support)
        try expect(library.bundledEntries.count == 20, "expected 20 bundled agent sounds")
        try expect(Set(library.bundledEntries.map(\.family)) == ["glass", "organic", "digital", "soft", "energetic"],
                   "sound families drifted")

        let imported = try library.importSound(from: bundled.appendingPathComponent("bloom.wav"))
        try expect(imported.imported && library.url(for: imported.id) != nil, "valid WAV import failed")
        try library.rename(imported.id, to: "My Bloom")
        try expect(library.importedEntries.first?.name == "My Bloom", "sound rename failed")
        try library.remove(imported.id)
        try expect(library.importedEntries.isEmpty && library.url(for: imported.id) == nil, "sound removal failed")
        let corrupt = temporary.appendingPathComponent("corrupt.wav")
        try Data("not audio".utf8).write(to: corrupt)
        do {
            _ = try library.importSound(from: corrupt)
            throw Failure(description: "corrupt audio import was accepted")
        } catch AgentSoundLibrary.LibraryError.unsupported {}
        let oversized = temporary.appendingPathComponent("oversized.wav")
        fm.createFile(atPath: oversized.path, contents: nil)
        let oversizedHandle = try FileHandle(forWritingTo: oversized)
        try oversizedHandle.truncate(atOffset: UInt64(20 * 1_024 * 1_024 + 1))
        try oversizedHandle.close()
        do {
            _ = try library.importSound(from: oversized)
            throw Failure(description: "oversized audio import was accepted")
        } catch AgentSoundLibrary.LibraryError.tooLarge {}

        let badge = AgentSignalBadgeView(frame: NSRect(x: 0, y: 0, width: 140, height: 22))
        let signal = AgentSignal(id: "qa-merge", kind: .gitMergeSucceeded, agentID: nil, tileID: UUID(),
                                 threadID: nil, occurredAt: Date(), source: .managedRuntime)
        badge.apply(signal)
        try expect(!badge.isHidden && badge.signal?.kind == .gitMergeSucceeded,
                   "merge visual did not render")
        try expect(badge.accessibilityLabel()?.contains("Merge") == true,
                   "merge visual lacks a non-color accessibility label")
        badge.apply(nil)
        try expect(badge.isHidden, "cleared signal remained visible")

        let suite = "array.agent-awareness.qa.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure(description: "could not create defaults suite") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = AgentSignalCenter(defaults: defaults, library: library, player: AgentSoundPlayer())
        let tileID = UUID()
        let event = AgentRuntimeEvent.turnCompleted(threadId: "qa", turnId: "turn", outcome: .completed, errorMessage: nil)
        try expect(center.ingest(event: event, agentID: nil, tileID: tileID)?.kind == .completed,
                   "completion signal was not coordinated")
        try expect(center.ingest(event: event, agentID: nil, tileID: tileID) == nil,
                   "replayed completion was not deduplicated")
        let request = AgentRuntimeEvent.userInputRequested(
            threadId: "qa", requestId: "request", questions: [.init(key: "choice", prompt: "Choose")])
        _ = center.ingest(event: request, agentID: nil, tileID: tileID)
        _ = center.ingest(event: .semanticSignal(threadId: "qa", itemId: "push", kind: .gitPushSucceeded),
                          agentID: nil, tileID: tileID)
        try expect(center.currentByTile[tileID]?.kind == .actionRequired,
                   "a Git achievement displaced persistent action-required attention")
        _ = AgentSoundSettingsView(defaults: defaults, library: library)

        // Sound on by default (decisions pass): the master switch reads ON when
        // nobody has set it, an explicit OFF stays off, and because every event
        // is still opt-in a fresh install hears nothing until one is enabled.
        final class RecordingPlayer: AgentSoundPlaying {
            var played: [AgentSoundReference] = []
            func play(_ reference: AgentSoundReference, priority: Int, volume: Double, library: AgentSoundLibrary) {
                played.append(reference)
            }
        }
        func freshSuite(_ label: String) throws -> (UserDefaults, String) {
            let name = "array.agent-awareness.\(label).\(UUID().uuidString)"
            guard let suite = UserDefaults(suiteName: name) else { throw Failure(description: "could not create suite \(label)") }
            return (suite, name)
        }
        func everyEvent(_ center: AgentSignalCenter) {
            let tile = UUID()
            _ = center.ingest(event: .turnCompleted(threadId: "fresh", turnId: "t1", outcome: .completed, errorMessage: nil),
                              agentID: nil, tileID: tile)
            _ = center.ingest(event: .turnCompleted(threadId: "fresh", turnId: "t2", outcome: .failed, errorMessage: "boom"),
                              agentID: nil, tileID: UUID())
            _ = center.ingest(event: request, agentID: nil, tileID: UUID())
            _ = center.ingest(event: .semanticSignal(threadId: "fresh", itemId: "push", kind: .gitPushSucceeded),
                              agentID: nil, tileID: UUID())
            _ = center.ingest(event: .semanticSignal(threadId: "fresh", itemId: "merge", kind: .gitMergeSucceeded),
                              agentID: nil, tileID: UUID())
        }
        let (unset, unsetName) = try freshSuite("unset")
        defer { unset.removePersistentDomain(forName: unsetName) }
        let unsetModel = SettingsModel(defaults: unset, navKeymap: .default, soundLibrary: library)
        try expect(unset.object(forKey: AgentSoundConfig.masterEnabledKey) == nil && unsetModel.soundsEnabled,
                   "an unset master switch must read ON in Settings — read \(unsetModel.soundsEnabled)")
        let freshPlayer = RecordingPlayer()
        everyEvent(AgentSignalCenter(defaults: unset, library: library, player: freshPlayer))
        try expect(freshPlayer.played.isEmpty,
                   "a fresh install with no event enabled must play NOTHING — played \(freshPlayer.played.map(\.rawValue))")
        unset.set(true, forKey: AgentSoundConfig.enabledKey(for: .completed))
        let oneEventPlayer = RecordingPlayer()
        everyEvent(AgentSignalCenter(defaults: unset, library: library, player: oneEventPlayer))
        try expect(oneEventPlayer.played == [AgentSoundReference(rawValue: "bloom")],
                   "turning on ONE event with the master untouched must just work — played \(oneEventPlayer.played.map(\.rawValue))")

        let (off, offName) = try freshSuite("off")
        defer { off.removePersistentDomain(forName: offName) }
        off.set(false, forKey: AgentSoundConfig.masterEnabledKey)
        off.set(true, forKey: AgentSoundConfig.enabledKey(for: .completed))
        let offModel = SettingsModel(defaults: off, navKeymap: .default, soundLibrary: library)
        try expect(!offModel.soundsEnabled, "an explicit OFF master switch must stay off in Settings")
        let offPlayer = RecordingPlayer()
        everyEvent(AgentSignalCenter(defaults: off, library: library, player: offPlayer))
        try expect(offPlayer.played.isEmpty,
                   "an explicit OFF master switch must silence an enabled event — played \(offPlayer.played.map(\.rawValue))")
        print("Agent awareness checks passed: 20 assets, import lifecycle, accessible visuals, deduped completion, master sound ON when unset and OFF when set off, a fresh install silent until one event is enabled")
    }
}

@MainActor
final class AgentSoundSettingsView: NSStackView {
    private let defaults: UserDefaults
    private let library: AgentSoundLibrary
    private var rulePopups: [AgentSignalKind: NSPopUpButton] = [:]
    private var importedPopup = NSPopUpButton()
    private var libraryObserver: NSObjectProtocol?

    init(defaults: UserDefaults, library: AgentSoundLibrary = .shared) {
        self.defaults = defaults
        self.library = library
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 12
        build()
        libraryObserver = NotificationCenter.default.addObserver(forName: .agentSoundLibraryDidChange, object: library, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadPopups() }
        }
    }

    isolated deinit {
        if let libraryObserver { NotificationCenter.default.removeObserver(libraryObserver) }
    }

    required init?(coder: NSCoder) { nil }

    private func build() {
        let master = NSButton(checkboxWithTitle: "Play agent sound indicators", target: self, action: #selector(masterChanged(_:)))
        master.state = AgentSoundConfig.isMasterEnabled(defaults: defaults) ? .on : .off
        addArrangedSubview(master)

        let slider = NSSlider(value: AgentSoundConfig.resolvedVolume(defaults: defaults), minValue: 0, maxValue: 1,
                              target: self, action: #selector(volumeChanged(_:)))
        slider.isContinuous = true
        slider.widthAnchor.constraint(equalToConstant: 260).isActive = true
        addArrangedSubview(horizontal([text("Volume"), slider]))

        for kind in AgentSignalKind.allCases.sorted(by: { $0.priority > $1.priority }) {
            let enabled = NSButton(checkboxWithTitle: kind.displayName, target: self, action: #selector(ruleEnabledChanged(_:)))
            enabled.identifier = NSUserInterfaceItemIdentifier(kind.rawValue)
            enabled.state = defaults.bool(forKey: AgentSoundConfig.enabledKey(for: kind)) ? .on : .off
            enabled.widthAnchor.constraint(equalToConstant: 140).isActive = true
            let popup = NSPopUpButton()
            popup.identifier = NSUserInterfaceItemIdentifier(kind.rawValue)
            popup.target = self
            popup.action = #selector(ruleSoundChanged(_:))
            rulePopups[kind] = popup
            let preview = NSButton(title: "Preview", target: self, action: #selector(previewRule(_:)))
            preview.identifier = NSUserInterfaceItemIdentifier(kind.rawValue)
            addArrangedSubview(horizontal([enabled, popup, preview]))
        }

        let divider = NSBox()
        divider.boxType = .separator
        divider.widthAnchor.constraint(equalToConstant: 430).isActive = true
        addArrangedSubview(divider)
        addArrangedSubview(text("Custom library"))
        importedPopup.frame.size.width = 220
        let importButton = NSButton(title: "Import…", target: self, action: #selector(importSound))
        let renameButton = NSButton(title: "Rename…", target: self, action: #selector(renameSound))
        let removeButton = NSButton(title: "Remove", target: self, action: #selector(removeSound))
        addArrangedSubview(horizontal([importedPopup, importButton, renameButton, removeButton]))
        reloadPopups()
    }

    private func reloadPopups() {
        for (kind, popup) in rulePopups {
            let selected = defaults.string(forKey: AgentSoundConfig.soundKey(for: kind))
                ?? AgentSoundRules.defaults[kind]!.sound.rawValue
            popup.removeAllItems()
            for entry in library.allEntries {
                popup.addItem(withTitle: entry.name)
                popup.lastItem?.representedObject = entry.id.rawValue
            }
            if let match = popup.itemArray.first(where: { ($0.representedObject as? String) == selected }) {
                popup.select(match)
            }
        }
        importedPopup.removeAllItems()
        for entry in library.importedEntries {
            importedPopup.addItem(withTitle: entry.name)
            importedPopup.lastItem?.representedObject = entry.id.rawValue
        }
        if library.importedEntries.isEmpty { importedPopup.addItem(withTitle: "No imported sounds") }
    }

    @objc private func masterChanged(_ sender: NSButton) { defaults.set(sender.state == .on, forKey: AgentSoundConfig.masterEnabledKey) }
    @objc private func volumeChanged(_ sender: NSSlider) { defaults.set(sender.doubleValue, forKey: AgentSoundConfig.volumeKey) }
    @objc private func ruleEnabledChanged(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let kind = AgentSignalKind(rawValue: raw) else { return }
        defaults.set(sender.state == .on, forKey: AgentSoundConfig.enabledKey(for: kind))
    }
    @objc private func ruleSoundChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.identifier?.rawValue, let kind = AgentSignalKind(rawValue: raw),
              let id = sender.selectedItem?.representedObject as? String else { return }
        defaults.set(id, forKey: AgentSoundConfig.soundKey(for: kind))
    }
    @objc private func previewRule(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let kind = AgentSignalKind(rawValue: raw),
              let id = rulePopups[kind]?.selectedItem?.representedObject as? String else { return }
        AgentSoundPlayer.shared.preview(AgentSoundReference(rawValue: id), library: library)
    }

    @objc private func importSound() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        do { for url in panel.urls { try library.importSound(from: url) } }
        catch { present(error) }
    }

    @objc private func renameSound() {
        guard let raw = importedPopup.selectedItem?.representedObject as? String else { return }
        let alert = NSAlert()
        alert.messageText = "Rename sound"
        let input = NSTextField(string: importedPopup.titleOfSelectedItem ?? "")
        input.frame.size = NSSize(width: 260, height: 24)
        alert.accessoryView = input
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try library.rename(AgentSoundReference(rawValue: raw), to: input.stringValue) }
        catch { present(error) }
    }

    @objc private func removeSound() {
        guard let raw = importedPopup.selectedItem?.representedObject as? String else { return }
        do { try library.remove(AgentSoundReference(rawValue: raw)) }
        catch { present(error) }
    }

    private func present(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }

    private func text(_ value: String) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        return label
    }

    private func horizontal(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }
}
