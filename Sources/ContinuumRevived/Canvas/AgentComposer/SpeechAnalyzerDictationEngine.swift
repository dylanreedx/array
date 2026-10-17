@preconcurrency import AVFoundation
import ContinuumRevivedCore
import Foundation
import Speech

/// DI-01 real backend: AVAudioEngine tap -> AVAudioConverter -> SpeechAnalyzer
/// with a `DictationTranscriber` (punctuation + volatile results).
///
/// App target only. Package.swift floor is macOS 14, so every use site gates on
/// `#available(macOS 26, *)`; below it the host constructs no engine and hides
/// the dictation affordance.
///
/// Threading: everything the protocol sees is `@MainActor`. The audio tap runs on
/// a realtime thread and lives in `CaptureGraph` (nonisolated, `@unchecked
/// Sendable`, immutable after init) so no main-actor isolation leaks into the
/// tap closure. Nothing here blocks the main thread: asset install, analyzer
/// prepare, finalize and result iteration all run in Tasks.
///
/// Late-event inertness: `generation` is bumped by every start/stop/cancel/fail
/// and every Task and graph callback captures the value it was born under. A
/// stale one drops its event, so a dead session is never resurrected and the
/// session's own `generation` guard has a second line behind it.
@available(macOS 26, *)
@MainActor
final class SpeechAnalyzerDictationEngine: DictationEngine {
    /// Fraction 0...1 of the model download while `prepare()` is installing
    /// assets; nil otherwise. Hosts may poll it to show progress in `.preparing`.
    private(set) var installProgress: Progress?

    private var prepared: Prepared?
    private var sink: (@MainActor (DictationEngineEvent) -> Void)?
    private var graph: CaptureGraph?
    private var analyzerTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    /// Last settled text, to decide whether the next segment needs a space.
    private var lastFinal = ""

    private struct Prepared {
        let transcriber: DictationTranscriber
        let analyzer: SpeechAnalyzer
        let format: AVAudioFormat
    }

    init() {}

    // MARK: - DictationEngine

    func prepare() async throws {
        try await Self.ensureMicrophoneAccess()
        guard let locale = await Self.resolveLocale() else {
            throw DictationFailure.unsupportedOnThisDevice
        }

        // Live punctuated hypotheses. `volatileResults` is what makes the
        // transcriber report provisional text before it settles.
        let transcriber = DictationTranscriber(
            locale: locale,
            contentHints: [],
            transcriptionOptions: [.punctuation],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        try await installAssetsIfNeeded(for: transcriber)
        try Task.checkCancellation()

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw DictationFailure.unsupportedOnThisDevice
        }
        // `.lingering` keeps the model resident for a while after a session, so
        // the second dictation in a row starts without reloading it.
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering)
        )
        do {
            // Loads the model now so the first word after `.ready` is not lost
            // to first-run latency.
            try await analyzer.prepareToAnalyze(in: format)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DictationFailure.assetsUnavailable
        }
        try Task.checkCancellation()
        prepared = Prepared(transcriber: transcriber, analyzer: analyzer, format: format)
    }

    func start(emitting sink: @escaping @MainActor (DictationEngineEvent) -> Void) throws {
        guard let prepared else { throw DictationFailure.recognizerFailed }
        self.prepared = nil
        teardown()
        generation &+= 1
        let generation = generation
        self.sink = sink
        runningAnalyzer = prepared.analyzer
        lastFinal = ""

        let (inputs, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        let graph = CaptureGraph(
            target: prepared.format,
            continuation: continuation,
            onLevel: { [weak self] level in
                Task { @MainActor in self?.emit(.level(level), generation: generation) }
            },
            onFailure: { [weak self] in
                Task { @MainActor in self?.fail(.audioEngineFailed, generation: generation) }
            }
        )
        do {
            try graph.start()
        } catch {
            graph.stop()
            self.sink = nil
            throw DictationFailure.audioEngineFailed
        }
        self.graph = graph

        let analyzer = prepared.analyzer
        let transcriber = prepared.transcriber
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    self?.handle(text: text, isFinal: result.isFinal, generation: generation)
                }
            } catch is CancellationError {
            } catch {
                self?.fail(.recognizerFailed, generation: generation)
            }
        }
        analyzerTask = Task { [weak self] in
            do {
                try await analyzer.start(inputSequence: inputs)
            } catch is CancellationError {
            } catch {
                self?.fail(.recognizerFailed, generation: generation)
            }
        }
        // Capture is live; recognition drains the stream as soon as it can.
        sink(.ready)
    }

    func stop() {
        guard let analyzer = runningAnalyzer, sink != nil else { return }
        let generation = generation
        // Stop the mic first, so the orange indicator ends with the user's
        // gesture; the flush below only drains audio already captured.
        graph?.stop()
        graph = nil
        let results = resultsTask
        Task { [weak self] in
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                await results?.value
                self?.finish(generation: generation)
            } catch {
                self?.fail(.recognizerFailed, generation: generation)
            }
        }
    }

    func cancel() {
        generation &+= 1
        sink = nil
        prepared = nil
        let analyzer = runningAnalyzer
        teardown()
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
    }

    // MARK: - Events (main actor, generation-guarded)

    private func handle(text: String, isFinal: Bool, generation: UInt64) {
        guard generation == self.generation, sink != nil else { return }
        if isFinal {
            guard !text.isEmpty else { return }
            let needsSpace = !lastFinal.isEmpty
                && lastFinal.last?.isWhitespace == false
                && text.first?.isWhitespace == false
            let settled = needsSpace ? " " + text : text
            lastFinal = settled
            emit(.final(settled), generation: generation)
        } else {
            emit(.volatile(text), generation: generation)
        }
    }

    private func emit(_ event: DictationEngineEvent, generation: UInt64) {
        guard generation == self.generation, let sink else { return }
        sink(event)
    }

    private func finish(generation: UInt64) {
        guard generation == self.generation, let sink else { return }
        self.sink = nil
        self.generation &+= 1
        teardown()
        sink(.finished)
    }

    private func fail(_ failure: DictationFailure, generation: UInt64) {
        guard generation == self.generation, let sink else { return }
        self.sink = nil
        self.generation &+= 1
        let analyzer = runningAnalyzer
        teardown()
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        sink(.failed(failure))
    }

    // MARK: - Teardown

    /// The analyzer of the running session, kept so stop/cancel/fail can reach it.
    private var runningAnalyzer: SpeechAnalyzer?

    /// Idempotent. Runs on every exit path: stops the tap and the engine,
    /// finishes the input stream and cancels both Tasks.
    private func teardown() {
        graph?.stop()
        graph = nil
        resultsTask?.cancel()
        resultsTask = nil
        analyzerTask?.cancel()
        analyzerTask = nil
        runningAnalyzer = nil
        installProgress = nil
    }

    // MARK: - Preparation helpers

    private static func ensureMicrophoneAccess() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw DictationFailure.microphonePermissionDenied
            }
        case .denied, .restricted:
            throw DictationFailure.microphonePermissionDenied
        @unknown default:
            throw DictationFailure.microphonePermissionDenied
        }
    }

    /// Current locale's nearest supported equivalent, else en-US's.
    private static func resolveLocale() async -> Locale? {
        if let match = await DictationTranscriber.supportedLocale(equivalentTo: .current) {
            return match
        }
        return await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
    }

    private func installAssetsIfNeeded(for transcriber: DictationTranscriber) async throws {
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed:
            return
        case .unsupported:
            throw DictationFailure.unsupportedOnThisDevice
        case .supported, .downloading:
            do {
                guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
                    return
                }
                installProgress = request.progress
                defer { installProgress = nil }
                try await request.downloadAndInstall()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw DictationFailure.assetsUnavailable
            }
        @unknown default:
            throw DictationFailure.assetsUnavailable
        }
    }
}

/// Mutable flag for AVAudioConverter's synchronous input block.
private final class OneShot: @unchecked Sendable { var taken = false }

/// Owns the AVAudioEngine and its tap. Every stored property is immutable after
/// init except engine state, which `start`/`stop` touch from the main actor only.
@available(macOS 26, *)
private final class CaptureGraph: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let target: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let onLevel: @Sendable (Float) -> Void
    private let onFailure: @Sendable () -> Void
    private var configObserver: NSObjectProtocol?
    private var running = false

    init(
        target: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        onLevel: @escaping @Sendable (Float) -> Void,
        onFailure: @escaping @Sendable () -> Void
    ) {
        self.target = target
        self.continuation = continuation
        self.onLevel = onLevel
        self.onFailure = onFailure
    }

    func start() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw DictationFailure.audioEngineFailed
        }
        let ratio = target.sampleRate / inputFormat.sampleRate
        let target = self.target
        let continuation = self.continuation
        let onLevel = self.onLevel

        // ~21 ms at 48 kHz, so the meter's envelope sees speech at syllable
        // rate. AVAudioEngine treats the size as a hint.
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            onLevel(Self.rms(of: buffer))
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            let supplied = OneShot()
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                if supplied.taken {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied.taken = true
                inputStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, error == nil, out.frameLength > 0 else { return }
            continuation.yield(AnalyzerInput(buffer: out))
        }

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [onFailure] _ in onFailure() }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            throw DictationFailure.audioEngineFailed
        }
        running = true
    }

    /// Idempotent. Always leaves the engine stopped, the tap removed and the
    /// input stream finished.
    func stop() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        continuation.finish()
    }

    /// RMS of channel 0 mapped through `DictationLevelMeter.normalized(rms:)`, so
    /// the `.level` event carries the 0...1 perceptual value the protocol promises.
    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += channel[i] * channel[i] }
        return DictationLevelMeter.normalized(rms: (sum / Float(buffer.frameLength)).squareRoot())
    }
}
