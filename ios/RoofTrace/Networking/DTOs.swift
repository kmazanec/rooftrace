import Foundation

struct SessionResponse: Codable, Equatable, Sendable {
    let appToken: String
    let expiresAt: Date
}

struct JobsResponse: Decodable, Equatable, Sendable {
    let jobs: [JobSummary]

    init(jobs: [JobSummary]) {
        self.jobs = jobs
    }
}

struct JobSummary: Decodable, Equatable, Sendable {
    let id: String
    let address: String
    let status: JobStatus
    let ready: Bool
    let totalAreaSqFt: Double?
    let shareToken: String?
    let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case address
        case rawStatus = "status"
        case ready
        case totalAreaSqFt
        case shareToken
        case createdAt
    }

    init(
        id: String,
        address: String,
        status: JobStatus,
        ready: Bool,
        totalAreaSqFt: Double?,
        shareToken: String?,
        createdAt: Date
    ) {
        self.id = id
        self.address = address
        self.status = status
        self.ready = ready
        self.totalAreaSqFt = totalAreaSqFt
        self.shareToken = shareToken
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        address = try container.decode(String.self, forKey: .address)
        let rawStatus = try container.decode(String.self, forKey: .rawStatus)
        ready = try container.decode(Bool.self, forKey: .ready)
        totalAreaSqFt = try container.decodeIfPresent(Double.self, forKey: .totalAreaSqFt)
        shareToken = try container.decodeIfPresent(String.self, forKey: .shareToken)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        status = JobStatus(rawValue: rawStatus, jobID: id, shareToken: shareToken, lastError: nil)
    }
}

struct JobStatusResponse: Decodable, Equatable, Sendable {
    let id: String
    let address: String
    let status: JobStatus
    let lastError: String?
    let ready: Bool
    let shareToken: String?
    let createdAt: Date
    // Present while the job's scan window is open; absent once the token expires.
    // Lets iOS offer the LiDAR walk-around for any job, not only ones it created.
    let captureToken: String?
    let captureTokenExpiresAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id
        case address
        case rawStatus = "status"
        case lastError
        case ready
        case shareToken
        case createdAt
        case captureToken
        case captureTokenExpiresAt
    }

    init(
        id: String,
        address: String,
        status: JobStatus,
        lastError: String?,
        ready: Bool,
        shareToken: String?,
        createdAt: Date,
        captureToken: String? = nil,
        captureTokenExpiresAt: Date? = nil
    ) {
        self.id = id
        self.address = address
        self.status = status
        self.lastError = lastError
        self.ready = ready
        self.shareToken = shareToken
        self.createdAt = createdAt
        self.captureToken = captureToken
        self.captureTokenExpiresAt = captureTokenExpiresAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        address = try container.decode(String.self, forKey: .address)
        let rawStatus = try container.decode(String.self, forKey: .rawStatus)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        ready = try container.decode(Bool.self, forKey: .ready)
        shareToken = try container.decodeIfPresent(String.self, forKey: .shareToken)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        captureToken = try container.decodeIfPresent(String.self, forKey: .captureToken)
        captureTokenExpiresAt = try container.decodeIfPresent(Date.self, forKey: .captureTokenExpiresAt)
        status = JobStatus(rawValue: rawStatus, jobID: id, shareToken: shareToken, lastError: lastError)
    }
}

struct CreateJobResponse: Codable, Equatable, Sendable {
    let jobId: String
    let captureToken: String
    let captureTokenExpiresAt: Date
}
