import Foundation

enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
}

struct Endpoint<Response: Decodable>: Sendable {
    let method: HTTPMethod
    let path: String
    let body: (any Encodable & Sendable)?
    let requiresAuth: Bool

    init(
        method: HTTPMethod,
        path: String,
        body: (any Encodable & Sendable)? = nil,
        requiresAuth: Bool = true
    ) {
        self.method = method
        self.path = path
        self.body = body
        self.requiresAuth = requiresAuth
    }
}

private struct SessionRequest: Encodable, Sendable {
    let username: String
    let password: String
}

extension Endpoint where Response == SessionResponse {
    static func createSession(username: String, password: String) -> Self {
        Endpoint(
            method: .post,
            path: "/api/v1/sessions",
            body: SessionRequest(username: username, password: password),
            requiresAuth: false
        )
    }
}

extension Endpoint where Response == JobsResponse {
    static func jobs() -> Self {
        Endpoint(method: .get, path: "/api/v1/jobs")
    }
}

extension Endpoint where Response == JobStatusResponse {
    static func job(id: String) -> Self {
        Endpoint(method: .get, path: "/api/v1/jobs/\(id)")
    }
}

private struct CreateJobRequest: Encodable, Sendable {
    let address: String
}

extension Endpoint where Response == CreateJobResponse {
    static func createJob(address: String) -> Self {
        Endpoint(method: .post, path: "/api/v1/jobs", body: CreateJobRequest(address: address))
    }
}

extension Endpoint where Response == RoofExport {
    static func report(id: String) -> Self {
        Endpoint(method: .get, path: "/api/v1/jobs/\(id).json")
    }
}

extension Endpoint where Response == LidarPoints {
    static func lidarPoints(id: String) -> Self {
        Endpoint(method: .get, path: "/api/v1/jobs/\(id)/lidar_points")
    }
}
