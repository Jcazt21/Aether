public import Foundation
import Synchronization

/// Routes requests by host to per-test handlers so suites can run in parallel.
public final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    public typealias Handler = @Sendable (URLRequest) throws -> (status: Int, body: Data)
    private static let handlers = Mutex<[String: Handler]>([:])

    /// Registers a handler and returns a unique base URL (`http://<uuid>.stub`) that routes to it.
    public static func register(_ handler: @escaping Handler) -> URL {
        let host = "\(UUID().uuidString.lowercased()).stub"
        handlers.withLock { $0[host] = handler }
        return URL(string: "http://\(host)")!
    }

    public static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override public class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".stub") == true }
    override public class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override public func startLoading() {
        let handler = Self.handlers.withLock { $0[request.url?.host ?? ""] }
        do {
            guard let handler else { throw URLError(.cannotFindHost) }
            let (status, body) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override public func stopLoading() {}
}
