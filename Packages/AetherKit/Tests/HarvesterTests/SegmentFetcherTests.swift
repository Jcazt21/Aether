import Foundation
import Testing
@testable import Harvester
import TestSupport

@Suite struct SegmentFetcherTests {
    private func fetcher() -> SegmentFetcher {
        SegmentFetcher(session: StubURLProtocol.session(), maxAttempts: 4, backoff: { _ in .milliseconds(1) })
    }

    @Test func retriesTransientFailuresThenSucceeds() async throws {
        let calls = Counter()
        let base = StubURLProtocol.register { _ in
            calls.increment() < 3 ? (503, Data()) : (200, Data([1, 2, 3]))
        }
        let bytes = try await fetcher().fetch(base.appending(path: "seg"))
        #expect(bytes == [1, 2, 3])
        #expect(calls.value == 3)
    }

    @Test func forbiddenIsNotRetried() async {
        let calls = Counter()
        let base = StubURLProtocol.register { _ in calls.increment(); return (403, Data()) }
        await #expect(throws: HarvestError.http(403)) { try await fetcher().fetch(base.appending(path: "seg")) }
        #expect(calls.value == 1)
    }

    @Test func givesUpAfterMaxAttempts() async {
        let base = StubURLProtocol.register { _ in (500, Data()) }
        await #expect(throws: HarvestError.http(500)) { try await fetcher().fetch(base.appending(path: "seg")) }
    }

    @Test func optionalFetchSwallowsErrors() async {
        let base = StubURLProtocol.register { _ in (404, Data()) }
        #expect(await fetcher().fetchOptional(base.appending(path: "cover.jpg")) == nil)
    }
}
