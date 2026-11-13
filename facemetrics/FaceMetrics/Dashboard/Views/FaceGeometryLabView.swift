import SwiftUI

struct FaceGeometryLabView: View {
    @EnvironmentObject var model: DashboardViewModel
    @State private var mode: MeshRenderMode = .wireframe
    @State private var followHead = true
    @State private var paused = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                InstrumentPanel("Face mesh", subtitle: "drag to rotate, pinch to zoom") {
                    VStack(spacing: 10) {
                        FaceMeshSceneView(processor: model.tracking.geometry, mode: mode, followHead: followHead, paused: paused)
                            .frame(height: 340)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(alignment: .topTrailing) {
                                if !model.snapshot.faceTracked {
                                    Text("Showing the last mesh received")
                                        .font(.caption2).foregroundStyle(Theme.warn)
                                        .padding(6)
                                }
                            }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(MeshRenderMode.allCases) { m in
                                    Chip(label: m.rawValue, selected: mode == m) { mode = m }
                                }
                                Chip(label: followHead ? "Follows head" : "Stabilised", selected: followHead, color: Theme.trace3) { followHead.toggle() }
                                Chip(label: paused ? "Frozen" : "Live", selected: paused, color: Theme.warn) { paused.toggle() }
                            }
                        }
                        if mode == .displacement {
                            HStack(spacing: 8) {
                                Button("Capture reference (neutral face)") { model.captureReferenceMesh() }
                                    .buttonStyle(InstrumentButtonStyle(tint: Theme.right))
                                Button("Clear") { model.clearReferenceMesh() }
                                    .buttonStyle(InstrumentButtonStyle(tint: Theme.textSecondary))
                                    .frame(width: 90)
                            }
                            SectionNote(text: model.snapshot.geometry?.hasReferenceMesh == true
                                ? "Colour shows each vertex's distance from the captured reference mesh: grey = 0 mm, amber = 10 mm or more. This is a geometric displacement, not a blend-shape value."
                                : "Capture a reference while the face is relaxed, then move the face to see which vertices displace.")
                        }
                    }
                }
                geometryPanel
                orientationPanel
            }
            .padding(14)
        }
    }

    private var geometryPanel: some View {
        let g = model.snapshot.geometry
        let r = g?.reading
        return InstrumentPanel("ARFaceGeometry") {
            VStack(alignment: .leading, spacing: 10) {
                ReadoutGrid(items: [
                    ("Vertices", Fmt.int(r?.vertexCount), nil),
                    ("Triangles", Fmt.int(r?.triangleCount), nil),
                    ("Texture coords", Fmt.int(r?.textureCoordinateCount), nil),
                    ("Mesh updates", Fmt.int(g?.meshUpdateCount), nil),
                    ("Last update", Fmt.ms(g?.secondsSinceLastMeshUpdate), "ago"),
                    ("Mean Δvertex", r?.meanVertexDisplacement.map { String(format: "%.2f mm", $0 * 1000) } ?? "—", nil),
                    ("Max Δvertex", r?.maxVertexDisplacement.map { String(format: "%.2f mm", $0 * 1000) } ?? "—", nil),
                    ("Width", r.map { Fmt.mm($0.boundingBoxMax.x - $0.boundingBoxMin.x) } ?? "—", nil),
                    ("Height", r.map { Fmt.mm($0.boundingBoxMax.y - $0.boundingBoxMin.y) } ?? "—", nil)
                ])
                SectionNote(text: "Vertex positions are in face-anchor space (metres). The topology (triangle indices) is fixed by ARKit; only vertex positions change per frame. Geometry is kept in memory for display and is written to disk only when geometry recording is switched on for a session.")
            }
        }
    }

    private var orientationPanel: some View {
        let h = model.snapshot.head?.reading
        return InstrumentPanel("Anchor transform", subtitle: "ARFaceAnchor.transform") {
            VStack(alignment: .leading, spacing: 10) {
                ReadoutGrid(items: [
                    ("World X", Fmt.mm(h?.worldPosition.x), nil),
                    ("World Y", Fmt.mm(h?.worldPosition.y), nil),
                    ("World Z", Fmt.mm(h?.worldPosition.z), nil),
                    ("View X", Fmt.mm(h?.viewPosition.x), nil),
                    ("View Y", Fmt.mm(h?.viewPosition.y), nil),
                    ("View Z", Fmt.mm(h?.viewPosition.z), nil),
                    ("Pitch", Fmt.deg(h?.viewEuler.x), nil),
                    ("Yaw", Fmt.deg(h?.viewEuler.y), nil),
                    ("Roll", Fmt.deg(h?.viewEuler.z), nil)
                ])
                if let m = h?.worldTransform {
                    let rows = MathSupport.rowMajor(m)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(0..<4, id: \.self) { r in
                            Text((0..<4).map { String(format: "% .4f", rows[r * 4 + $0]) }.joined(separator: "  "))
                                .font(.caption2.monospaced())
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
        }
    }
}
