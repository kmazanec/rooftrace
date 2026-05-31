import Foundation
import simd

/// The frozen `prompt_label` enum (manifest_version 1.0.0). Order is the
/// walk-around order: 4 corners + 4 facades, interleaved. `allCases` is the
/// capture sequence; `rawValue` is the on-wire string.
enum PromptLabel: String, Codable, CaseIterable {
    case frontLeftCorner = "front_left_corner"
    case frontFacade = "front_facade"
    case frontRightCorner = "front_right_corner"
    case rightFacade = "right_facade"
    case backRightCorner = "back_right_corner"
    case backFacade = "back_facade"
    case backLeftCorner = "back_left_corner"
    case leftFacade = "left_facade"
}

/// High-accuracy GPS fix at session start (the coarse ICP alignment seed).
/// `altitudeM` is HAE (WGS84 ellipsoidal height from `CLLocation.ellipsoidalAltitude`),
/// NEVER MSL — see ADR-007 amendment.
struct GPSOrigin: Codable, Equatable {
    let latitude: Double
    let longitude: Double
    let altitudeM: Double
    let horizontalAccuracyM: Double
    let verticalAccuracyM: Double
    let timestamp: String

    enum CodingKeys: String, CodingKey {
        case latitude, longitude
        case altitudeM = "altitude_m"
        case horizontalAccuracyM = "horizontal_accuracy_m"
        case verticalAccuracyM = "vertical_accuracy_m"
        case timestamp
    }
}

/// Per-capture GPS fix. HAE altitude, never MSL.
struct GPSFix: Codable, Equatable {
    let latitude: Double
    let longitude: Double
    let altitudeM: Double
    let horizontalAccuracyM: Double
    let verticalAccuracyM: Double

    enum CodingKeys: String, CodingKey {
        case latitude, longitude
        case altitudeM = "altitude_m"
        case horizontalAccuracyM = "horizontal_accuracy_m"
        case verticalAccuracyM = "vertical_accuracy_m"
    }
}

struct DeviceInfo: Codable, Equatable {
    let model: String
    let modelIdentifier: String
    let osVersion: String
    let appVersion: String

    enum CodingKeys: String, CodingKey {
        case model
        case modelIdentifier = "model_identifier"
        case osVersion = "os_version"
        case appVersion = "app_version"
    }
}

/// Row-major camera matrices. Build these via `MatrixSerializer.rowMajor` —
/// never flatten the ARKit column-major simd matrix directly.
struct CameraPose: Codable, Equatable {
    /// 9 numbers, row-major 3x3.
    let intrinsicsRowMajor: [Double]
    /// 16 numbers, row-major 4x4 world->camera.
    let worldToCameraRowMajor: [Double]

    enum CodingKeys: String, CodingKey {
        case intrinsicsRowMajor = "intrinsics_row_major"
        case worldToCameraRowMajor = "world_to_camera_row_major"
    }

    /// Builds from ARKit simd matrices with the explicit row-major transpose.
    init(intrinsics: simd_float3x3, worldToCamera: simd_float4x4) {
        self.intrinsicsRowMajor = MatrixSerializer.rowMajor(intrinsics)
        self.worldToCameraRowMajor = MatrixSerializer.rowMajor(worldToCamera)
    }

    init(intrinsicsRowMajor: [Double], worldToCameraRowMajor: [Double]) {
        self.intrinsicsRowMajor = intrinsicsRowMajor
        self.worldToCameraRowMajor = worldToCameraRowMajor
    }
}

/// Frozen reference-frame discriminant for ARKit attitude data.
enum AttitudeReferenceFrame: String, Codable, Equatable {
    case xArbitraryZVertical = "xArbitraryZVertical"
}

/// Device attitude as a quaternion only (no Euler angles — ambiguous + gimbal lock).
struct AttitudeQuaternion: Codable, Equatable {
    let quaternionW: Double
    let quaternionX: Double
    let quaternionY: Double
    let quaternionZ: Double
    let referenceFrame: AttitudeReferenceFrame

    enum CodingKeys: String, CodingKey {
        case quaternionW = "quaternion_w"
        case quaternionX = "quaternion_x"
        case quaternionY = "quaternion_y"
        case quaternionZ = "quaternion_z"
        case referenceFrame = "reference_frame"
    }

    init(quaternionW: Double, quaternionX: Double, quaternionY: Double, quaternionZ: Double, referenceFrame: AttitudeReferenceFrame) {
        self.quaternionW = quaternionW
        self.quaternionX = quaternionX
        self.quaternionY = quaternionY
        self.quaternionZ = quaternionZ
        self.referenceFrame = referenceFrame
    }

    /// Builds from an ARKit `simd_quatf` (vector is (x, y, z), `real` is w).
    init(quaternion q: simd_quatf, referenceFrame: AttitudeReferenceFrame) {
        self.quaternionW = Double(q.real)
        self.quaternionX = Double(q.imag.x)
        self.quaternionY = Double(q.imag.y)
        self.quaternionZ = Double(q.imag.z)
        self.referenceFrame = referenceFrame
    }
}

/// One of the 8 captures.
struct CaptureEntry: Codable, Equatable {
    let captureIndex: Int
    let promptLabel: PromptLabel
    let photoFilename: String
    let depthFilename: String
    let timestamp: String
    let gps: GPSFix?
    let cameraPose: CameraPose
    let attitude: AttitudeQuaternion
    /// const 1000.0 per schema.
    let depthScale: Double
    /// const "mm_as_uint16" per schema.
    let depthUnit: String
    let depthRangeM: [Double]

    enum CodingKeys: String, CodingKey {
        case captureIndex = "capture_index"
        case promptLabel = "prompt_label"
        case photoFilename = "photo_filename"
        case depthFilename = "depth_filename"
        case timestamp
        case gps
        case cameraPose = "camera_pose"
        case attitude
        case depthScale = "depth_scale"
        case depthUnit = "depth_unit"
        case depthRangeM = "depth_range_m"
    }

    init(
        captureIndex: Int, promptLabel: PromptLabel, photoFilename: String,
        depthFilename: String, timestamp: String, gps: GPSFix?, cameraPose: CameraPose,
        attitude: AttitudeQuaternion, depthRangeM: [Double]
    ) {
        self.captureIndex = captureIndex
        self.promptLabel = promptLabel
        self.photoFilename = photoFilename
        self.depthFilename = depthFilename
        self.timestamp = timestamp
        self.gps = gps
        self.cameraPose = cameraPose
        self.attitude = attitude
        self.depthScale = 1000.0
        self.depthUnit = "mm_as_uint16"
        self.depthRangeM = depthRangeM
    }
}

/// The fused ARKit world mesh metadata. filename/format/coordinate_frame are
/// const per schema.
struct WorldMesh: Codable, Equatable {
    let filename: String
    let format: String
    let coordinateFrame: String
    let vertexCount: Int
    let faceCount: Int

    enum CodingKeys: String, CodingKey {
        case filename, format
        case coordinateFrame = "coordinate_frame"
        case vertexCount = "vertex_count"
        case faceCount = "face_count"
    }

    init(vertexCount: Int, faceCount: Int) {
        self.filename = "arkit_mesh.obj"
        self.format = "obj"
        self.coordinateFrame = "arkit_session_local"
        self.vertexCount = vertexCount
        self.faceCount = faceCount
    }
}

/// The top-level capture-bundle manifest. Mirrors `shared/ios_session_schema.json`
/// exactly (manifest_version 1.0.0). `additionalProperties:false` on the schema
/// side means any field drift fails CI validation loudly.
struct CaptureSessionManifest: Codable, Equatable {
    let manifestVersion: String
    let sessionID: String
    let jobID: String
    let startedAt: String
    let endedAt: String
    let deviceInfo: DeviceInfo
    let gpsOrigin: GPSOrigin?
    let captures: [CaptureEntry]
    let worldMesh: WorldMesh

    enum CodingKeys: String, CodingKey {
        case manifestVersion = "manifest_version"
        case sessionID = "session_id"
        case jobID = "job_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case deviceInfo = "device_info"
        case gpsOrigin = "gps_origin"
        case captures
        case worldMesh = "world_mesh"
    }

    init(
        sessionID: String, jobID: String, startedAt: String, endedAt: String,
        deviceInfo: DeviceInfo, gpsOrigin: GPSOrigin?, captures: [CaptureEntry],
        worldMesh: WorldMesh
    ) {
        self.manifestVersion = "1.0.0"
        self.sessionID = sessionID
        self.jobID = jobID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.deviceInfo = deviceInfo
        self.gpsOrigin = gpsOrigin
        self.captures = captures
        self.worldMesh = worldMesh
    }

    // MARK: - JSON coders

    /// Shared encoder: stable key ordering for deterministic multipart bytes.
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static let decoder = JSONDecoder()

    /// ISO 8601 UTC with fractional seconds (e.g. 2026-05-28T14:32:00.000Z).
    /// Timestamps are stored as Strings in the manifest, but this is the canonical
    /// formatter the capture pipeline uses to produce them.
    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}
