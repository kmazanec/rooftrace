import SceneKit
import SwiftUI
import UIKit

/// Native 3D roof viewer (ADR-013, the iOS counterpart of the web deck.gl view):
/// facets rendered as true tilted planes coloured by pitch, an optional LiDAR
/// point cloud, and an orbit camera. Built on SceneKit (Apple-native, no
/// dependencies). Stateless re-render: a new `scene`/`selectedFacetID` rebuilds
/// the node graph; the camera keeps its pose across selection changes.
struct RoofSceneView: UIViewRepresentable {
    let scene: RoofProjection.Scene
    let showPoints: Bool
    let selectedFacetID: String?
    var onSelectFacet: ((String?) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(onSelectFacet: onSelectFacet) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = UIColor(named: "Brand/gray100") ?? .systemGray6
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true     // built-in orbit/pinch/pan
        view.autoenablesDefaultLighting = true
        view.scene = SCNScene()
        context.coordinator.onSelectFacet = onSelectFacet

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        view.addGestureRecognizer(tap)
        context.coordinator.sceneView = view
        rebuild(view, context: context)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.onSelectFacet = onSelectFacet
        // Rebuild only when the geometry inputs changed; selection-only changes
        // recolour in place so the camera and point cloud don't churn.
        let signature = Signature(scene: scene, showPoints: showPoints)
        if context.coordinator.signature != signature {
            context.coordinator.signature = signature
            rebuild(view, context: context)
        }
        recolourFacets(view, selectedFacetID: selectedFacetID)
    }

    // MARK: - Build

    private func rebuild(_ view: SCNView, context: Context) {
        let root = SCNScene()
        let container = SCNNode()
        container.name = "roof"

        for facet in scene.facets {
            if let node = Self.facetNode(facet) {
                container.addChildNode(node)
            }
        }

        if showPoints, !scene.points.isEmpty {
            container.addChildNode(Self.pointCloudNode(scene.points))
        }

        root.rootNode.addChildNode(container)
        root.rootNode.addChildNode(Self.cameraNode(radius: scene.radiusM))
        view.scene = root
        recolourFacets(view, selectedFacetID: selectedFacetID)
    }

    private func recolourFacets(_ view: SCNView, selectedFacetID: String?) {
        guard let container = view.scene?.rootNode.childNode(withName: "roof", recursively: false) else { return }
        for node in container.childNodes where node.name?.hasPrefix("facet:") == true {
            let facetID = String(node.name!.dropFirst("facet:".count))
            let selected = facetID == selectedFacetID
            let pitch = scene.facets.first { $0.facetID == facetID }?.pitchRatio
            node.geometry?.firstMaterial?.diffuse.contents = Self.facetColor(pitchRatio: pitch, selected: selected)
        }
    }

    // MARK: - Nodes

    private static func facetNode(_ facet: RoofProjection.ProjectedFacet) -> SCNNode? {
        let ring = dedupedClosedRing(facet.points)
        guard ring.count >= 3 else { return nil }

        let positions = ring.map { SCNVector3($0.x, $0.y, $0.z) }
        let source = SCNGeometrySource(vertices: positions)
        // Triangle fan over the (near-planar) facet polygon.
        var indices: [Int32] = []
        for i in 1..<(ring.count - 1) {
            indices.append(0)
            indices.append(Int32(i))
            indices.append(Int32(i + 1))
        }
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.isDoubleSided = true
        material.diffuse.contents = facetColor(pitchRatio: facet.pitchRatio, selected: false)
        geometry.firstMaterial = material

        let node = SCNNode(geometry: geometry)
        node.name = "facet:\(facet.facetID)"
        return node
    }

    private static func pointCloudNode(_ points: [SIMD3<Double>]) -> SCNNode {
        let vertices = points.map { SCNVector3($0.x, $0.y, $0.z) }
        let source = SCNGeometrySource(vertices: vertices)
        let indices = (0..<Int32(vertices.count)).map { $0 }
        let element = SCNGeometryElement(indices: indices, primitiveType: .point)
        element.pointSize = 2
        element.minimumPointScreenSpaceRadius = 1.5
        element.maximumPointScreenSpaceRadius = 4
        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(named: "Brand/gray600") ?? .gray
        material.lightingModel = .constant
        geometry.firstMaterial = material
        let node = SCNNode(geometry: geometry)
        node.name = "lidar"
        return node
    }

    private static func cameraNode(radius: Double) -> SCNNode {
        let camera = SCNCamera()
        camera.zNear = 0.1
        camera.zFar = max(radius * 20, 100)
        let node = SCNNode()
        node.camera = camera
        // A 3/4 orbit view: back, up, and to the side, looking at the origin.
        let d = max(radius * 2.2, 8)
        node.position = SCNVector3(d * 0.7, d * 0.8, d * 0.9)
        node.look(at: SCNVector3(0, 0, 0))
        node.name = "camera"
        return node
    }

    // MARK: - Colour

    /// Muted single-hue ramp by pitch (flat = gray, steep = orange), matching the
    /// web viewer's "colour by pitch, not a rainbow" choice. Selected = blue.
    static func facetColor(pitchRatio: Double?, selected: Bool) -> UIColor {
        if selected {
            return (UIColor(named: "CC/blue") ?? .systemBlue).withAlphaComponent(0.85)
        }
        let base = UIColor(named: "Brand/gray400") ?? .lightGray
        let steep = UIColor(named: "Brand/orange") ?? .orange
        let t = CGFloat(min(max((pitchRatio ?? 0) / 12.0, 0), 1)) // 0/12..12/12
        return blend(base, steep, t).withAlphaComponent(0.9)
    }

    private static func blend(_ a: UIColor, _ b: UIColor, _ t: CGFloat) -> UIColor {
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        return UIColor(
            red: ar + (br - ar) * t,
            green: ag + (bg - ag) * t,
            blue: ab + (bb - ab) * t,
            alpha: aa + (ba - aa) * t
        )
    }

    /// Drop a trailing vertex equal to the first (closed rings repeat it) so the
    /// triangle fan doesn't generate a degenerate sliver.
    private static func dedupedClosedRing(_ points: [SIMD3<Double>]) -> [SIMD3<Double>] {
        guard let first = points.first, let last = points.last, points.count > 1 else { return points }
        let same = abs(first.x - last.x) < 1e-6 && abs(first.y - last.y) < 1e-6 && abs(first.z - last.z) < 1e-6
        return same ? Array(points.dropLast()) : points
    }

    // MARK: - Interaction

    struct Signature: Equatable {
        let facetIDs: [String]
        let pointCount: Int
        let showPoints: Bool

        init(scene: RoofProjection.Scene, showPoints: Bool) {
            facetIDs = scene.facets.map(\.facetID)
            pointCount = scene.points.count
            self.showPoints = showPoints
        }
    }

    final class Coordinator: NSObject {
        weak var sceneView: SCNView?
        var onSelectFacet: ((String?) -> Void)?
        var signature: Signature?

        init(onSelectFacet: ((String?) -> Void)?) {
            self.onSelectFacet = onSelectFacet
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = sceneView else { return }
            let location = gesture.location(in: view)
            let hits = view.hitTest(location, options: [SCNHitTestOption.searchMode: SCNHitTestSearchMode.closest.rawValue])
            if let name = hits.first?.node.name, name.hasPrefix("facet:") {
                onSelectFacet?(String(name.dropFirst("facet:".count)))
            } else {
                onSelectFacet?(nil)
            }
        }
    }
}
