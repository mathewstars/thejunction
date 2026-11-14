import Foundation

/// Establishes how the ARKit uptime clock of one recording maps onto wall-clock time.
///
/// `timestamp_s` in the FaceMetrics CSV is `ARFrame.timestamp`: seconds since the phone booted, not
/// since 1970. HealthKit samples carry wall-clock dates. The two can only be combined through an
/// anchor that pairs one uptime value with one wall-clock instant:
///
/// 1. `session.json`: `createdAt` (wall clock when recording started) with `recordingStartTimestamp`
///    (uptime of the first kept sample). Preferred, because it is what the recorder wrote at the moment.
/// 2. A marker in `session.json` that has both `wallClock` and `startTimestamp`.
/// 3. The CSV's own `wall_clock_unix_s` column, if present: median of (wall − uptime) over all rows.
///
/// Whatever anchor is chosen, the per-row CSV wall clock (when present) is used as a cross-check and
/// the residual is reported. A residual above `maxAcceptableResidual` is a warning, not a silent fix.
public enum TimestampAligner {

    public static let maxAcceptableResidual: Double = 2.0

    public static func align(session: ARKitSession) -> TimestampAlignment {
        var warnings: [String] = []
        var method: AlignmentMethod = .unaligned
        var offset: Double? = nil

        let firstUptime = session.frames.first?.timestampUptime
        let lastUptime = session.frames.last?.timestampUptime

        if let m = session.manifest, let created = m.createdAt, let startUptime = m.recordingStartTimestamp {
            offset = created.timeIntervalSince1970 - startUptime
            method = .sessionManifest
            if let f = firstUptime, abs(f - startUptime) > 1 {
                warnings.append("First CSV timestamp_s (\(f)) differs from manifest recordingStartTimestamp (\(startUptime)) by \(String(format: "%.2f", f - startUptime)) s.")
            }
        } else if let m = session.manifest, let marker = m.markers?.first(where: { $0.wallClock != nil }), let wc = marker.wallClock {
            offset = wc.timeIntervalSince1970 - marker.startTimestamp
            method = .markerWallClock
            warnings.append("Anchored on marker '\(marker.label)' because the manifest has no createdAt/recordingStartTimestamp pair.")
        }

        // Cross-check (or fallback) with the per-row wall clock.
        let residualPairs: [(Double, Double)] = session.frames.compactMap { f in
            guard let w = f.wallClockUnix else { return nil }
            return (f.timestampUptime, w)
        }
        var residualMedian: Double? = nil
        var residualMax: Double? = nil
        if !residualPairs.isEmpty {
            let perRowOffsets = residualPairs.map { $0.1 - $0.0 }
            let csvOffset = LocalStatistics.median(perRowOffsets)!
            if let o = offset {
                let residuals = perRowOffsets.map { $0 - o }
                residualMedian = LocalStatistics.median(residuals)
                residualMax = residuals.map { abs($0) }.max()
                if let rm = residualMedian, abs(rm) > maxAcceptableResidual {
                    warnings.append("CSV wall_clock_unix_s disagrees with the manifest anchor by a median of \(String(format: "%.2f", rm)) s. The manifest anchor was kept; check the device clock.")
                }
            } else {
                offset = csvOffset
                method = .csvWallClock
                let spread = perRowOffsets.map { abs($0 - csvOffset) }.max() ?? 0
                residualMedian = 0
                residualMax = spread
                warnings.append("No session.json anchor; offset taken from the CSV wall_clock_unix_s column (median over \(perRowOffsets.count) rows).")
            }
        } else if offset != nil {
            warnings.append("CSV has no wall_clock_unix_s column; the manifest anchor could not be cross-checked.")
        }

        if offset == nil {
            warnings.append("No wall-clock anchor available. Frames keep recording-relative time only and cannot be joined with HealthKit.")
        }

        var a = TimestampAlignment(sessionID: session.id, method: method, uptimeToUnixOffsetSeconds: offset,
                                   recordingStartWallClock: nil, recordingEndWallClock: nil,
                                   crossCheckResidualMedianSeconds: residualMedian, crossCheckResidualMaxSeconds: residualMax,
                                   crossCheckRows: residualPairs.count, warnings: warnings)
        if let o = offset {
            if let f = firstUptime { a.recordingStartWallClock = Date(timeIntervalSince1970: f + o) }
            if let l = lastUptime { a.recordingEndWallClock = Date(timeIntervalSince1970: l + o) }
        }
        return a
    }

    /// Applies an alignment to a window's uptime bounds.
    public static func wallClockRange(_ alignment: TimestampAlignment?, startUptime: Double, endUptime: Double) -> (Date?, Date?) {
        guard let a = alignment else { return (nil, nil) }
        return (a.wallClock(forUptime: startUptime), a.wallClock(forUptime: endUptime))
    }
}
