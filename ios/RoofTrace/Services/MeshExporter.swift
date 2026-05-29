import Foundation
import simd
#if canImport(ARKit)
import ARKit
import ModelIO
import MetalKit
#endif

/// Exports the accumulated ARKit world mesh to a single Wavefront OBJ in
/// `arkit_session_local` coordinates (gravity-aligned Y-up, meters). Each
/// `ARMeshAnchor`'s vertices are transformed anchor-local -> world via
/// `anchor.transform`, concatenated, decimated toward < 50k triangles, and
/// written via `MDLAsset.export`. Empty mesh -> `.emptyMesh`; an export over
/// 256 MB -> `.oversized` (the Rails controller separately rejects > 200 MB).
///
/// Device-only (needs Metal + ModelIO with the ARKit geometry); CI never runs it.
final class MeshExporter {
    static let maxBytes = 256 * 1024 * 1024
    static let targetTriangles = 50_000

    #if canImport(ARKit)
    func export(anchors: [ARMeshAnchor]) async -> Result<MeshExportResult, MeshExportError> {
        guard !anchors.isEmpty else { return .failure(.emptyMesh) }

        guard let device = MTLCreateSystemDefaultDevice() else {
            return .failure(.exportFailed)
        }
        let allocator = MTKMeshBufferAllocator(device: device)
        let asset = MDLAsset(bufferAllocator: allocator)

        var totalVertices = 0
        var totalFaces = 0

        for anchor in anchors {
            let geometry = anchor.geometry
            let vertexCount = geometry.vertices.count
            guard vertexCount > 0 else { continue }

            // Transform each vertex anchor-local -> world.
            var worldVertices = [Float]()
            worldVertices.reserveCapacity(vertexCount * 3)
            let vBuffer = geometry.vertices
            let vPtr = vBuffer.buffer.contents().advanced(by: vBuffer.offset)
            for i in 0..<vertexCount {
                let p = vPtr.advanced(by: i * vBuffer.stride)
                    .assumingMemoryBound(to: (Float, Float, Float).self).pointee
                let local = SIMD4<Float>(p.0, p.1, p.2, 1)
                let world = anchor.transform * local
                worldVertices.append(world.x)
                worldVertices.append(world.y)
                worldVertices.append(world.z)
            }
            totalVertices += vertexCount

            // Faces.
            let faceBuffer = geometry.faces
            let faceCount = faceBuffer.count
            totalFaces += faceCount

            let vData = Data(bytes: worldVertices, count: worldVertices.count * MemoryLayout<Float>.size)
            let vertexBuffer = allocator.newBuffer(with: vData, type: .vertex)

            let indexBytesPerIndex = faceBuffer.bytesPerIndex
            let indexData = Data(bytes: faceBuffer.buffer.contents(),
                                 count: faceCount * faceBuffer.indexCountPerPrimitive * indexBytesPerIndex)
            let indexBuffer = allocator.newBuffer(with: indexData, type: .index)

            let indexType: MDLIndexBitDepth = indexBytesPerIndex == 2 ? .uInt16 : .uInt32
            let submesh = MDLSubmesh(indexBuffer: indexBuffer,
                                     indexCount: faceCount * faceBuffer.indexCountPerPrimitive,
                                     indexType: indexType,
                                     geometryType: .triangles,
                                     material: nil)

            let vertexDescriptor = MDLVertexDescriptor()
            vertexDescriptor.attributes[0] = MDLVertexAttribute(
                name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
            vertexDescriptor.layouts[0] = MDLVertexBufferLayout(stride: MemoryLayout<Float>.size * 3)

            let mdlMesh = MDLMesh(vertexBuffer: vertexBuffer, vertexCount: vertexCount,
                                  descriptor: vertexDescriptor, submeshes: [submesh])
            asset.add(mdlMesh)
        }

        guard totalVertices > 0 else { return .failure(.emptyMesh) }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("arkit_mesh.obj")
        try? FileManager.default.removeItem(at: url)
        do {
            try asset.export(to: url)
        } catch {
            return .failure(.exportFailed)
        }

        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
           size > Self.maxBytes {
            return .failure(.oversized)
        }

        return .success(MeshExportResult(fileURL: url, vertexCount: totalVertices, faceCount: totalFaces))
    }
    #endif
}
