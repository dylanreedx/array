import Foundation

public enum FilePreview: Equatable, Sendable {
    public static let maxReadBytes = 1_024 * 1_024

    case text(String)
    case unavailable(String)

    public static func load(path: String) -> FilePreview {
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return .unavailable("File not found")
        }

        if let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
           values.isRegularFile == false {
            return .unavailable("File not found")
        }

        if let byteCount = ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.intValue,
           byteCount > maxReadBytes {
            return .unavailable("File too large to preview (> 1 MB)")
        }

        do {
            let data = try Data(contentsOf: url)
            guard data.count <= maxReadBytes else {
                return .unavailable("File too large to preview (> 1 MB)")
            }
            guard !hasNonUTF8BOM(data), !containsNullByte(data) else {
                return .unavailable("Binary file -- open in preferred editor")
            }
            guard let text = String(data: data, encoding: .utf8) else {
                return .unavailable("Binary file -- open in preferred editor")
            }
            return .text(text)
        } catch {
            return .unavailable("File not found")
        }
    }

    private static func hasNonUTF8BOM(_ data: Data) -> Bool {
        let bytes = Array(data.prefix(4))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return false }
        return bytes.starts(with: [0xFE, 0xFF])
            || bytes.starts(with: [0xFF, 0xFE])
            || bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF])
            || bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00])
    }

    private static func containsNullByte(_ data: Data) -> Bool {
        data.prefix(8 * 1_024).contains(0)
    }
}
