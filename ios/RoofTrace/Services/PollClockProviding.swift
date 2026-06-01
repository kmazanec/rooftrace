import Foundation

protocol PollClockProviding: Sendable {
    func sleep(for interval: TimeInterval) async throws
}

struct RealPollClock: PollClockProviding {
    func sleep(for interval: TimeInterval) async throws {
        let nanoseconds = UInt64(max(0, interval) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}
