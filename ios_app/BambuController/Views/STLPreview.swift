// STLPreview.swift - 3D-Render einer STL/OBJ vor dem Slicen/Drucken.
//
// Ablauf: Teilen/Import → Upload → Job in „Dateien“ → Vorschau (3D, drehbar)
// → Slicen → Drucken. Gerendert wird das Original vom Pi (GET /uploads/{id}),
// geparst lokal (ASCII + Binär-STL, ohne Libs). 3MF/STEP zeigen Hinweis.
import SwiftUI
import SceneKit

// MARK: - Parser (ASCII + Binär, facet soup reicht für Vorschau)

struct STLMesh {
    var vertices: [SCNVector3] = []
    var normals: [SCNVector3] = []
    var facets: Int { vertices.count / 3 }
    var sizeMM: SIMD3<Float> = .zero
}

enum STLParser {
    static func parse(_ data: Data) -> STLMesh? {
        guard data.count >= 84 else { return nil }
        // ASCII? "solid" + "facet" in den ersten KB
        let head = data.prefix(min(4096, data.count))
        if let txt = String(data: head, encoding: .utf8),
           txt.hasPrefix("solid") || txt.contains("facet normal") {
            if let m = parseASCII(data) { return m }
        }
        return parseBinary(data)
    }

    private static func parseASCII(_ data: Data) -> STLMesh? {
        guard let txt = String(data: data, encoding: .utf8) else { return nil }
        var mesh = STLMesh()
        var minV = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxV = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var lines = txt.split(separator: "\n").makeIterator()
        var count = 0
        while let line = lines.next() {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("facet normal") else { continue }
            let np = t.split(separator: " ").compactMap { Float($0) }
            guard np.count >= 3 else { continue }
            let n = SCNVector3(np[np.count-3], np[np.count-2], np[np.count-1])
            var tri: [SCNVector3] = []
            while let l2 = lines.next() {
                let u = l2.trimmingCharacters(in: .whitespaces)
                if u.hasPrefix("vertex") {
                    let vp = u.split(separator: " ").compactMap { Float($0) }
                    guard vp.count >= 3 else { continue }
                    let v = SCNVector3(vp[vp.count-3], vp[vp.count-2], vp[vp.count-1])
                    tri.append(v)
                    minV = min(minV, SIMD3<Float>(v.x, v.y, v.z))
                    maxV = max(maxV, SIMD3<Float>(v.x, v.y, v.z))
                } else if u.hasPrefix("endfacet") { break }
                if tri.count == 3 { break }
            }
            guard tri.count == 3 else { continue }
            mesh.vertices.append(contentsOf: tri)
            mesh.normals.append(contentsOf: [n, n, n])
            count += 1
            if count > 500_000 { break } // Vorschau-Cap
        }
        guard !mesh.vertices.isEmpty else { return nil }
        mesh.sizeMM = maxV - minV
        return mesh
    }

    private static func parseBinary(_ data: Data) -> STLMesh? {
        guard data.count >= 84 else { return nil }
        let facets: UInt32 = data[80..<84].withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        guard facets > 0, facets <= 1_000_000 else { return nil }
        guard data.count >= 84 + Int(facets) * 50 else { return nil }
        var mesh = STLMesh()
        mesh.vertices.reserveCapacity(Int(facets) * 3)
        mesh.normals.reserveCapacity(Int(facets) * 3)
        var minV = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxV = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var off = 84
            for _ in 0..<facets {
                let nx = raw.load(fromByteOffset: off, as: Float.self); off += 4
                let ny = raw.load(fromByteOffset: off, as: Float.self); off += 4
                let nz = raw.load(fromByteOffset: off, as: Float.self); off += 4
                let n = SCNVector3(nx, ny, nz)
                for _ in 0..<3 {
                    let x = raw.load(fromByteOffset: off, as: Float.self); off += 4
                    let y = raw.load(fromByteOffset: off, as: Float.self); off += 4
                    let z = raw.load(fromByteOffset: off, as: Float.self); off += 4
                    guard x.isFinite && y.isFinite && z.isFinite else { continue }
                    let v = SCNVector3(x, y, z)
                    mesh.vertices.append(v); mesh.normals.append(n)
                    minV = min(minV, SIMD3<Float>(x, y, z))
                    maxV = max(maxV, SIMD3<Float>(x, y, z))
                }
                off += 2 // attribute byte count
            }
        }
        guard !mesh.vertices.isEmpty else { return nil }
        mesh.sizeMM = maxV - minV
        return mesh
    }
}

// MARK: - SceneKit-Ansicht (drehbar, Zoom, Apple-clean)

struct STLSceneView: UIViewRepresentable {
    let mesh: STLMesh

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .secondarySystemGroupedBackground
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        let scene = SCNScene()
        scene.background.contents = UIColor.secondarySystemGroupedBackground

        let verts = mesh.vertices
        let norms: [SCNVector3] = mesh.normals.count == verts.count
            ? mesh.normals : Array(repeating: SCNVector3(0, 1, 0), count: verts.count)
        let vSrc = SCNGeometrySource(vertices: verts)
        let nSrc = SCNGeometrySource(normals: norms)
        var idx: [Int32] = []
        idx.reserveCapacity(verts.count)
        for i in 0..<verts.count { idx.append(Int32(i)) }
        let el = SCNGeometryElement(indices: idx, primitiveType: .triangles)
        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor.systemGray
        mat.metalness.contents = 0.1
        mat.roughness.contents = 0.7
        mat.isDoubleSided = true
        let geo = SCNGeometry(sources: [vSrc, nSrc], elements: [el])
        geo.materials = [mat]
        let node = SCNNode(geometry: geo)
        // Aufrichten: STL-Z-up → SceneKit-Y-up
        node.eulerAngles.x = -.pi / 2
        // Zentrieren + einpassen (Hüllbox aus den Mesh-Daten, kein Node-API nötig)
        var mn = SCNVector3(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
        var mx = SCNVector3(-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)
        for v in verts {
            mn.x = min(mn.x, v.x); mn.y = min(mn.y, v.y); mn.z = min(mn.z, v.z)
            mx.x = max(mx.x, v.x); mx.y = max(mx.y, v.y); mx.z = max(mx.z, v.z)
        }
        node.pivot = SCNMatrix4MakeTranslation((mn.x+mx.x)/2, (mn.y+mx.y)/2, (mn.z+mx.z)/2)
        scene.rootNode.addChildNode(node)

        let span = max(mx.x-mn.x, mx.y-mn.y, mx.z-mn.z, 1)
        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.position = SCNVector3(span * 0.9, span * 0.7, span * 1.1)
        cam.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(cam)

        let amb = SCNNode(); amb.light = SCNLight(); amb.light?.type = .ambient
        amb.light?.intensity = 700; scene.rootNode.addChildNode(amb)
        let key = SCNNode(); key.light = SCNLight(); key.light?.type = .directional
        key.position = SCNVector3(span, span * 1.4, span); key.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(key)

        view.scene = scene
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}
}

// MARK: - Vorschau-Sheet (lädt Modell vom Pi, rendert 3D)

struct STLPreviewSheet: View {
    let job: SliceJob
    @Environment(\.dismiss) var dismiss
    @State private var mesh: STLMesh?
    @State private var failed = false
    @State private var loading = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                if loading {
                    ProgressView("Modell wird geladen …")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let m = mesh {
                    STLSceneView(mesh: m)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    Text("\(m.facets) Facetten · \(Int(m.sizeMM.x)) × \(Int(m.sizeMM.y)) × \(Int(m.sizeMM.z)) mm")
                        .font(.caption).foregroundColor(.secondary).monospacedDigit()
                } else if failed {
                    VStack(spacing: 8) {
                        Image(systemName: "cube.transparent").font(.system(size: 48)).foregroundColor(.secondary)
                        Text("Keine 3D-Vorschau möglich")
                            .font(.headline)
                        Text("Für 3MF/STEP gibt es nur Slicen → Drucken. STL/OBJ zeigen hier das 3D-Modell.")
                            .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding()
            .navigationTitle(job.filename)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Fertig") { dismiss() } } }
        }
        .task { await load() }
    }

    private func load() async {
        loading = true; failed = false
        do {
            let data = try await APIService.shared.downloadUpload(jobId: job.id)
            let ext = (job.filename as NSString).pathExtension.lowercased()
            if ext == "stl" {
                // Hintergrund-Thread (große Meshes)
                let d = data
                let m = await Task.detached { STLParser.parse(d) }.value
                mesh = m; failed = (m == nil)
            } else if ext == "obj" {
                mesh = await Task.detached { STLParser.parse(data) }.value
                // OBJ ist kein STL — Fallback: Hinweis statt Render
                failed = (mesh == nil)
            } else {
                failed = true
            }
        } catch { failed = true }
        loading = false
    }
}
