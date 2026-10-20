public import Foundation

public struct SegmentFetcher: Sendable {
    private let session: URLSession
    private let maxAttempts: Int
    private let backoff: @Sendable (Int) -> Duration

    public init(session: URLSession, maxAttempts: Int = 4,
                backoff: @escaping @Sendable (Int) -> Duration = { .milliseconds(500 << $0) }) {
        self.session = session
        self.maxAttempts = maxAttempts
        self.backoff = backoff
    }

    /// Audio session: no URL cache (never duplicate tens of MB in ~/Library/Caches), fresh responses only.
    public static func makeAudioSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 6
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }

    /// Retries network errors, 429 and 5xx with backoff. 4xx (notably 403 = expired signature) fail immediately.
    public func fetch(_ url: URL) async throws -> [UInt8] {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(from: url)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200 { return [UInt8](data) }
                let retryable = status == 429 || status >= 500
                guard retryable, attempt + 1 < maxAttempts else { throw HarvestError.http(status) }
            } catch let error as URLError where error.code != .cancelled && attempt + 1 < maxAttempts {
                // fall through to backoff
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            }
            try await Task.sleep(for: backoff(attempt))
            attempt += 1
        }
    }

    public func fetchOptional(_ url: URL) async -> Data? {
        (try? await fetch(url)).map { Data($0) }
    }
}
