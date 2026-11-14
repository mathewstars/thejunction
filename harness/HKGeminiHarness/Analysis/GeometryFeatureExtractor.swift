import Foundation

/// Optional experiment: numbers derived from the 1,220-vertex face mesh. Vertex positions never leave
/// this function; only aggregate displacement and extent statistics come out.
public enum GeometryFeatureExtractor {

    public static func features(_ g: ARKitGeometryData) -> GeometryDerivedFeatures {
        let recs = g.records
        let vc = g.summary.vertexCount
        var meanDisp: [Double] = []
        var maxDisp: [Double] = []
        var extents: [[Double]] = []
        var symmetryErrors: [Double] = []

        for (i, r) in recs.enumerated() {
            let v = r.vertices
            guard v.count == vc * 3, vc > 0 else { continue }
            var minX = Double.infinity, minY = Double.infinity, minZ = Double.infinity
            var maxX = -Double.infinity, maxY = -Double.infinity, maxZ = -Double.infinity
            var mirrorErr = 0.0
            for k in 0..<vc {
                let x = Double(v[k * 3]), y = Double(v[k * 3 + 1]), z = Double(v[k * 3 + 2])
                minX = min(minX, x); minY = min(minY, y); minZ = min(minZ, z)
                maxX = max(maxX, x); maxY = max(maxY, y); maxZ = max(maxZ, z)
            }
            extents.append([maxX - minX, maxY - minY, maxZ - minZ])
            // Crude mirror symmetry: distance between each vertex and the nearest vertex of the mirrored
            // cloud is expensive; instead compare the x-centroid of the left and right halves.
            var left = 0.0, right = 0.0, nl = 0, nr = 0
            for k in 0..<vc {
                let x = Double(v[k * 3])
                if x < 0 { left += -x; nl += 1 } else { right += x; nr += 1 }
            }
            if nl > 0, nr > 0 { mirrorErr = abs(left / Double(nl) - right / Double(nr)) }
            symmetryErrors.append(mirrorErr)

            if i > 0, recs[i - 1].vertices.count == v.count {
                let p = recs[i - 1].vertices
                var sum = 0.0, mx = 0.0
                for k in 0..<vc {
                    let dx = Double(v[k * 3] - p[k * 3]), dy = Double(v[k * 3 + 1] - p[k * 3 + 1]), dz = Double(v[k * 3 + 2] - p[k * 3 + 2])
                    let d = (dx * dx + dy * dy + dz * dz).squareRoot()
                    sum += d; mx = max(mx, d)
                }
                meanDisp.append(sum / Double(vc)); maxDisp.append(mx)
            }
        }
        let meanExtent: [Double]? = extents.isEmpty ? nil : (0..<3).map { axis in extents.map { $0[axis] }.reduce(0, +) / Double(extents.count) }
        return GeometryDerivedFeatures(
            recordCount: recs.count, vertexCount: vc,
            meanInterRecordDisplacementM: LocalStatistics.mean(meanDisp), maxInterRecordDisplacementM: maxDisp.max(),
            displacementStdM: LocalStatistics.standardDeviation(meanDisp), meanBoundingBoxExtentM: meanExtent,
            leftRightSymmetryError: LocalStatistics.mean(symmetryErrors),
            supportingMeasurements: ["geometry.bin vertex positions (face-anchor space)", "geometry.json triangle_indices"])
    }
}
