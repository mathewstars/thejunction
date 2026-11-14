import Foundation

/// Writes exports into Documents/HKGeminiExports so they show up in the Files app
/// (`UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` are set in Info.plist).
public enum FileExport {

    public static var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("HKGeminiExports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func timestamped(_ name: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        let stamp = f.string(from: Date())
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        return ext.isEmpty ? "\(stem)-\(stamp)" : "\(stem)-\(stamp).\(ext)"
    }

    @discardableResult
    public static func writeJSON<T: Encodable>(_ value: T, name: String, pretty: Bool = true) throws -> URL {
        let data = try JSONValue.encoder(pretty: pretty).encode(value)
        let url = directory.appendingPathComponent(timestamped(name))
        try data.write(to: url, options: .atomic)
        return url
    }

    @discardableResult
    public static func writeCSV(rows: [[String]], name: String) throws -> URL {
        var text = ""
        for row in rows {
            text += row.map(escapeCSV).joined(separator: ",") + "\n"
        }
        let url = directory.appendingPathComponent(timestamped(name))
        try text.data(using: .utf8)!.write(to: url, options: .atomic)
        return url
    }

    @discardableResult
    public static func writeText(_ text: String, name: String) throws -> URL {
        let url = directory.appendingPathComponent(timestamped(name))
        try text.data(using: .utf8)!.write(to: url, options: .atomic)
        return url
    }

    public static func escapeCSV(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    public static func listExports() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }
    }
}
