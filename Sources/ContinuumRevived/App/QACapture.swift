import AppKit
import ContinuumRevivedCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class QACapture {
    struct Manifest: Codable {
        var flow: String
        var generatedAt: Date
        var entries: [Entry]
    }

    struct Entry: Codable {
        var step: String
        var tSec: Double
        var png: String?
        var canvasState: CanvasState?
        var notes: String?
    }

    private let outputDirectory: URL
    private let flowName: String
    private let fileManager: FileManager
    private var entries: [Entry] = []

    init?(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        guard let rawOutput = environment["CONTINUUM_QA_CAPTURE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawOutput.isEmpty
        else {
            return nil
        }

        self.outputDirectory = URL(fileURLWithPath: rawOutput, isDirectory: true)
        let rawFlow = environment["CONTINUUM_QA_FLOW"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let rawFlow, !rawFlow.isEmpty {
            self.flowName = rawFlow
        } else {
            self.flowName = "default-smoke"
        }
        self.fileManager = fileManager

        do {
            try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        } catch {
            fputs("QA capture setup failed: \(error)\n", stderr)
            return nil
        }
    }

    func capture(
        step: String,
        tSec: Double,
        window: NSWindow,
        canvasState: CanvasState? = nil,
        notes: String? = nil
    ) {
        let pngName = "\(String(format: "%02d", entries.count + 1))-\(Self.slug(step)).png"
        let pngURL = outputDirectory.appendingPathComponent(pngName, isDirectory: false)
        var png: String?
        var entryNotes = notes

        switch writePNG(for: window, to: pngURL) {
        case .success:
            png = pngName
        case let .failure(error):
            let captureNote = "PNG capture failed: \(error)"
            entryNotes = [entryNotes, captureNote].compactMap { $0 }.joined(separator: "; ")
            fputs("QA capture \(step) failed: \(error)\n", stderr)
        }

        entries.append(Entry(
            step: step,
            tSec: tSec,
            png: png,
            canvasState: canvasState,
            notes: entryNotes
        ))
    }

    func writeManifest() {
        let manifest = Manifest(flow: flowName, generatedAt: Date(), entries: entries)
        let manifestURL = outputDirectory.appendingPathComponent("manifest.json", isDirectory: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(manifest)
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            fputs("QA capture manifest write failed: \(error)\n", stderr)
        }
    }

    private func writePNG(for window: NSWindow, to url: URL) -> Result<Void, Error> {
        guard let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            CGWindowID(window.windowNumber),
            [.boundsIgnoreFraming]
        ) else {
            return .failure(CaptureError.windowImageUnavailable)
        }

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return .failure(CaptureError.destinationUnavailable)
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            return .failure(CaptureError.finalizeFailed)
        }

        return .success(())
    }

    private static func slug(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "capture" : collapsed
    }

    private enum CaptureError: LocalizedError {
        case windowImageUnavailable
        case destinationUnavailable
        case finalizeFailed

        var errorDescription: String? {
            switch self {
            case .windowImageUnavailable:
                return "window image unavailable"
            case .destinationUnavailable:
                return "PNG destination unavailable"
            case .finalizeFailed:
                return "PNG finalize failed"
            }
        }
    }
}
