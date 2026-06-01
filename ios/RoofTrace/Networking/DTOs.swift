import Foundation

struct SessionResponse: Codable, Equatable, Sendable {
    let appToken: String
    let expiresAt: Date
}

struct JobsResponse: Codable, Equatable, Sendable {
    let jobs: [JobSummary]
}

struct JobSummary: Codable, Equatable, Sendable {
    let id: String
    let address: String
    let status: String
    let ready: Bool
    let totalAreaSqFt: Double?
    let shareToken: String?
    let createdAt: Date
}

struct JobStatusResponse: Decodable, Equatable, Sendable {
    let id: String
    let address: String
    let status: JobStatus
    let lastError: String?
    let ready: Bool
    let shareToken: String?
    let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case address
        case rawStatus = "status"
        case lastError
        case ready
        case shareToken
        case createdAt
    }

    init(
        id: String,
        address: String,
        status: JobStatus,
        lastError: String?,
        ready: Bool,
        shareToken: String?,
        createdAt: Date
    ) {
        self.id = id
        self.address = address
        self.status = status
        self.lastError = lastError
        self.ready = ready
        self.shareToken = shareToken
        self.createdAt = createdAt
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
        status = JobStatus(rawValue: rawStatus, jobID: id, shareToken: shareToken, lastError: lastError)
    }
}

struct CreateJobResponse: Codable, Equatable, Sendable {
    let jobId: String
    let captureToken: String
    let captureTokenExpiresAt: Date
}
