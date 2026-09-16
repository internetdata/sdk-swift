import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

@testable import InternetData

/// The client's timeout, bounding a whole ATTEMPT from the request to the decoded
/// answer. Every stall is a real socket that took the request, and every failure
/// is checked for having taken at least the timeout: a refused connection is a
/// retryable network error too, and would otherwise pass for the deadline firing.
@Suite("Timeout")
struct TimeoutTests {
    static let timeout: Duration = .milliseconds(300)
    /// Timer slack, so a deadline that fired a hair early is not read as none.
    static let atLeast: Duration = .milliseconds(250)

    enum Call: String, CaseIterable, Sendable {
        case list, metadata, checksums, downloads, downloadURL
    }

    // The transport's own bound ends when the head arrives, so nothing else would
    // ever end a JSON body that stops. The redirect has no body to stall, so its
    // origin never answers at all.
    @Test(
        "the client's timeout bounds every API call, body included", .timeLimit(.minutes(1)),
        arguments: Call.allCases,
    )
    func everyCallIsBounded(_ call: Call) async throws {
        let origin = try await TestOrigin.start { _ in call == .downloadURL ? .silence : .stalledJSON }
        defer { Task { try? await origin.stop() } }
        let client = Self.client(origin)

        let started = ContinuousClock.now
        let failure = try await Self.failure(of: call, on: client)
        let elapsed = ContinuousClock.now - started

        #expect(failure.kind == .network)
        #expect(failure.isRetryable)
        #expect(failure.message.hasPrefix("the request timed out"), "\(failure.message)")
        #expect(elapsed >= Self.atLeast, "failed after \(elapsed), before the deadline could fire")
        #expect(elapsed < .seconds(5), "failed after \(elapsed), not at the client's timeout")
        #expect(origin.receivedPaths.count == 1)
    }

    // No single read waits more than 20 ms, so only a bound on the whole attempt
    // can end this before the listing completes at about a second.
    @Test("a trickled body is bounded as a whole, not per read", .timeLimit(.minutes(1)))
    func aTrickledBodyIsBoundedAsAWhole() async throws {
        let origin = try await TestOrigin.start { _ in .trickledListing }
        defer { Task { try? await origin.stop() } }
        let client = Self.client(origin)

        let started = ContinuousClock.now
        let failure = await #expect(throws: InternetDataError.self) {
            try await client.database.list()
        }
        let elapsed = ContinuousClock.now - started

        #expect(try #require(failure).kind == .network)
        #expect(elapsed >= Self.atLeast, "failed after \(elapsed), before the deadline could fire")
        #expect(elapsed < .milliseconds(900), "failed after \(elapsed), not at the client's timeout")
    }

    @Test("each retry gets the whole timeout again", .timeLimit(.minutes(1)))
    func eachRetryGetsTheWholeTimeout() async throws {
        let origin = try await TestOrigin.start { _ in .silence }
        defer { Task { try? await origin.stop() } }
        let client = Self.client(origin, retries: 1)

        let started = ContinuousClock.now
        await #expect(throws: InternetDataError.self) {
            try await client.database.list()
        }

        #expect(origin.receivedPaths.count == 2)
        #expect(ContinuousClock.now - started >= Self.atLeast * 2)
    }

    // The attempt ends at the response head, or it would abandon any database that
    // takes longer to move than a listing may take.
    @Test("a slow transfer is not cut off by the client's timeout", .timeLimit(.minutes(1)))
    func aSlowTransferOutlivesTheTimeout() async throws {
        let payload = DownloadTransferTests.payload
        let origins = try await DownloadTransferTests.Origins.start(.trickled(payload), timeout: Self.timeout)
        defer { origins.stop() }

        let started = ContinuousClock.now
        let bytes = try await origins.client.database.downloadBytes("bogon_ip_v1", format: .csvgz)

        #expect([UInt8](bytes) == payload)
        #expect(ContinuousClock.now - started > Self.timeout, "the transfer was not slow")
    }

    // ...but up to the head it is an attempt like any other.
    @Test("a transfer whose storage never answers is bounded", .timeLimit(.minutes(1)))
    func aSilentStorageIsBounded() async throws {
        let origins = try await DownloadTransferTests.Origins.start(.silence, timeout: Self.timeout)
        defer { origins.stop() }

        let started = ContinuousClock.now
        let failure = await #expect(throws: InternetDataError.self) {
            try await origins.client.database.downloadBytes("bogon_ip_v1", format: .csvgz)
        }
        let elapsed = ContinuousClock.now - started

        #expect(try #require(failure).kind == .network)
        #expect(elapsed >= Self.atLeast, "failed after \(elapsed), before the deadline could fire")
        #expect(elapsed < .seconds(5), "failed after \(elapsed), not at the client's timeout")
    }

    // Cancelling releases the connection, but only a transport that HONORS
    // cancellation then returns, and a supplied one need not.
    @Test("a transport that ignores cancellation is still bounded", .timeLimit(.minutes(1)))
    func aDeafTransportIsStillBounded() async throws {
        let client = InternetDataClient(
            options: .init(retries: 0, timeout: Self.timeout, transport: DeafTransport()),
        )

        let started = ContinuousClock.now
        let failure = await #expect(throws: InternetDataError.self) {
            try await client.database.list()
        }

        #expect(try #require(failure).kind == .network)
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test("cancelling a call propagates at once, not at the deadline")
    func cancellingATimedCallPropagates() async throws {
        let stub = StubTransport(
            [StubTransport.listPath: .json(["databases": []])], delay: .seconds(5),
        )
        let client = InternetDataClient(
            options: .init(retries: 0, timeout: .seconds(3), transport: stub),
        )

        let started = ContinuousClock.now
        let call = Task { try await client.database.list() }
        try await Task.sleep(for: .milliseconds(100))
        call.cancel()

        await #expect(throws: CancellationError.self) { try await call.value }
        #expect(ContinuousClock.now - started < .seconds(2), "the cancellation waited for the deadline")
    }

    static func client(_ origin: TestOrigin, retries: Int = 0) -> InternetDataClient {
        InternetDataClient(
            options: .init(
                apiKey: "key", baseURL: URL(string: "http://127.0.0.1:\(origin.port)")!, retries: retries,
                timeout: timeout,
            ),
        )
    }

    static func failure(of call: Call, on client: InternetDataClient) async throws -> InternetDataError {
        let caught = await #expect(throws: InternetDataError.self) {
            switch call {
            case .list:
                _ = try await client.database.list()
            case .metadata:
                _ = try await client.database.metadata(id: "bogon_ip_v1")
            case .checksums:
                _ = try await client.database.checksums(id: "bogon_ip_v1", format: .csvgz)
            case .downloads:
                _ = try await client.database.downloads()
            case .downloadURL:
                _ = try await client.database.downloadURL(id: "bogon_ip_v1", format: .csvgz)
            }
        }
        return try #require(caught)
    }
}

/// Answers after 30 seconds whatever happens, cancellation included: a detached
/// task is not cancelled with the task awaiting it.
struct DeafTransport: ClientTransport {
    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String,
    ) async throws -> (HTTPResponse, HTTPBody?) {
        await Task.detached { try? await Task.sleep(for: .seconds(30)) }.value
        return (HTTPResponse(status: .ok), nil)
    }
}
