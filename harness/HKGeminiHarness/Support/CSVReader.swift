import Foundation

/// Streaming CSV reader: reads the file in 1 MB chunks and hands over one parsed row at a time, so a
/// 60 MB FaceMetrics recording never has to be held as a single String. Handles RFC 4180 quoting
/// (quoted fields, doubled quotes, embedded commas and newlines) and both \n and \r\n line endings.
public final class CSVReader {

    public enum ReaderError: LocalizedError {
        case cannotOpen(URL)
        case emptyFile
        public var errorDescription: String? {
            switch self {
            case .cannotOpen(let u): return "Cannot open \(u.lastPathComponent)"
            case .emptyFile: return "The CSV file is empty"
            }
        }
    }

    private let url: URL
    private let chunkSize = 1 << 20

    public init(url: URL) { self.url = url }

    /// Calls `onRow` for every row after the header. Return false from `onRow` to stop early.
    public func read(onHeader: ([String]) throws -> Void, onRow: ([String]) throws -> Bool) throws {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw ReaderError.cannotOpen(url) }
        defer { try? handle.close() }

        var field = [UInt8]()
        var row: [String] = []
        var inQuotes = false
        var sawQuoteInQuotes = false
        var isHeaderDone = false
        var anyByte = false
        var stop = false
        field.reserveCapacity(64)

        func finishField() {
            row.append(String(decoding: field, as: UTF8.self))
            field.removeAll(keepingCapacity: true)
        }
        func finishRow() throws {
            finishField()
            // Skip blank lines.
            if row.count == 1 && row[0].isEmpty { row.removeAll(); return }
            if !isHeaderDone {
                try onHeader(row.map { $0.trimmingCharacters(in: .whitespaces) })
                isHeaderDone = true
            } else {
                if try !onRow(row) { stop = true }
            }
            row.removeAll(keepingCapacity: true)
        }

        while !stop {
            let data = handle.readData(ofLength: chunkSize)
            if data.isEmpty { break }
            anyByte = true
            for b in data {
                if inQuotes {
                    if sawQuoteInQuotes {
                        sawQuoteInQuotes = false
                        if b == UInt8(ascii: "\"") { field.append(b); continue }   // escaped quote
                        inQuotes = false
                        // fall through: b terminates the quoted field
                    } else {
                        if b == UInt8(ascii: "\"") { sawQuoteInQuotes = true } else { field.append(b) }
                        continue
                    }
                }
                switch b {
                case UInt8(ascii: ","): finishField()
                case UInt8(ascii: "\n"): try finishRow(); if stop { break }
                case UInt8(ascii: "\r"): break
                case UInt8(ascii: "\""): if field.isEmpty { inQuotes = true } else { field.append(b) }
                default: field.append(b)
                }
                if stop { break }
            }
        }
        guard anyByte else { throw ReaderError.emptyFile }
        if !stop && (!field.isEmpty || !row.isEmpty) { try finishRow() }
    }
}
