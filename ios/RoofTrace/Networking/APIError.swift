import Foundation

enum APIError: Error, Equatable {
    case unauthorized
    case notFound
    case server(Int)
    case transport
    case decoding
}
