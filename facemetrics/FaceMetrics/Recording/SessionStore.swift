import Foundation

/// A recorded session on disk, listed from Documents/FaceMetricsSessions.
struct RecordedSessionSummary: Identifiable {
    let id: String
    let folder: URL
    let manifest: SessionManifest?
    let files: [URL]
    let totalBytes: Int64
    let createdAt: Date

    var durationSeconds: Double { manifest?.durationSeconds ?? 0 }
    var sampleCount: Int { manifest?.sampleCount ?? 0 }
    var hasGeometry: Bool {
        if let m = manifest { return m.configuration.includeFaceGeometry }
        return files.contains { $0.lastPathComponent == "geometry.bin" }
    }
}

/// Lists, shares and deletes recorded sessions. Pure file-system work; call from any queue.
final class SessionStore {

    let rootURL: URL

    init(rootURL: URL = SessionRecorder.sessionsRootURL) {
        self.rootURL = rootURL
    }

    func list() -> [RecordedSessionSummary] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        var out: [RecordedSessionSummary] = []
        for folder in folders {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
            var bytes: Int64 = 0
            for f in files {
                if let size = try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize { bytes += Int64(size) }
            }
            var manifest: SessionManifest? = nil
            let manifestURL = folder.appendingPathComponent("session.json")
            if let data = try? Data(contentsOf: manifestURL) {
                manifest = try? SessionManifest.decoder().decode(SessionManifest.self, from: data)
            }
            let created = manifest?.createdAt
                ?? (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate)
                ?? Date.distantPast
            out.append(RecordedSessionSummary(id: folder.lastPathComponent, folder: folder, manifest: manifest,
                                              files: files.sorted { $0.lastPathComponent < $1.lastPathComponent },
                                              totalBytes: bytes, createdAt: created))
        }
        return out.sorted { $0.createdAt > $1.createdAt }
    }

    func delete(id: String) throws {
        let folder = rootURL.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.removeItem(at: folder)
    }

    func deleteAll() throws {
        for s in list() { try delete(id: s.id) }
    }

    /// Files suitable for the share sheet. Geometry files are included only when asked.
    func shareableFiles(for session: RecordedSessionSummary, includeGeometry: Bool) -> [URL] {
        session.files.filter { url in
            let name = url.lastPathComponent
            if name.hasPrefix("geometry") { return includeGeometry }
            return true
        }
    }
}
