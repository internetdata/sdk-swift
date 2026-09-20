import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

@testable import InternetData

/// The client's timeout and the per-call one, each bounding a whole ATTEMPT from
/// the request to the decoded answer. Every stall is a real socket that took the
/// request, and every failure is checked for having taken at least the timeout: a
/// refused connection is a retryable network error too, and would otherwise pass
/// for the deadline firing.
@Suite("Timeout")
struct TimeoutTests {
    static let timeout: Duration = .milliseconds(300)
    /// Timer slack, so a deadline that fired a hair early is not read as none.
    static let atLeast: Duration = .milliseconds(250)

    /// The calls that ask the API a question. The transfers are absent because
    /// they take no per-call timeout at all, which
    /// ``onlyTheJSONCallsTakeATimeout()`` is what asserts.
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

    // The client is given thirty seconds, so only the per-call value can end any
    // of these. The head lands at once and the body then arrives a byte at a
    // time, so no single read ever waits long enough to be what fired; the
    // redirect has no body to trickle, so its origin never answers at all.
    @Test(
        "a per-call timeout below the client's bounds every call", .timeLimit(.minutes(1)),
        arguments: Call.allCases,
    )
    func aPerCallTimeoutBoundsEveryCall(_ call: Call) async throws {
        let origin = try await TestOrigin.start { _ in call == .downloadURL ? .silence : .trickledListing }
        defer { Task { try? await origin.stop() } }
        let client = Self.client(origin, timeout: .seconds(30))

        let started = ContinuousClock.now
        let failure = try await Self.failure(of: call, on: client, timeout: Self.timeout)
        let elapsed = ContinuousClock.now - started

        #expect(failure.kind == .network)
        #expect(failure.isRetryable)
        #expect(failure.message.hasPrefix("the request timed out"), "\(failure.message)")
        #expect(elapsed >= Self.atLeast, "failed after \(elapsed), before the deadline could fire")
        // Under the listing's own thousand milliseconds, so a per-call value that
        // was accepted and ignored cannot pass by the body simply finishing.
        #expect(elapsed < .milliseconds(900), "failed after \(elapsed), not at the per-call deadline")
        #expect(origin.receivedPaths.count == 1)
    }

    // A per-call value kept anywhere but the call itself - written into the client,
    // or into the API struct it is reached through - passes the first of these and
    // fails the second.
    @Test("a call with no timeout falls back to the client's", .timeLimit(.minutes(1)))
    func aCallWithoutAnOverrideUsesTheClients() async throws {
        let origin = try await TestOrigin.start { _ in .trickledListing }
        defer { Task { try? await origin.stop() } }
        let client = Self.client(origin)

        let databases = try await client.database.list(timeout: .seconds(10))
        let started = ContinuousClock.now
        let failure = await #expect(throws: InternetDataError.self) {
            try await client.database.downloads()
        }
        let elapsed = ContinuousClock.now - started

        #expect(databases.isEmpty)
        #expect(try #require(failure).kind == .network)
        #expect(elapsed >= Self.atLeast, "failed after \(elapsed), before the client's deadline could fire")
        #expect(elapsed < .milliseconds(900), "failed after \(elapsed), not at the client's timeout")
    }

    // A method reference names every parameter and never applies a default, so
    // the annotations below ARE the signatures. A `timeout` added to a transfer,
    // or dropped from a call that asks the API a question, stops this file
    // compiling - which is how Swift refuses the option rather than accepting it
    // and quietly doing nothing with it.
    @Test("every JSON call takes a per-call timeout, and no transfer does")
    func onlyTheJSONCallsTakeATimeout() async throws {
        let stub = StubTransport([StubTransport.listPath: .json(["databases": []])])
        let client = InternetDataClient(options: .init(apiKey: "key", transport: stub))

        let list: (Duration?) async throws -> [Database] = client.database.list(timeout:)
        let metadata: (String, Duration?) async throws -> DatabaseMetadata =
            client.database.metadata(id:timeout:)
        let checksums: (String, DatabaseFormat, Duration?) async throws -> DatabaseChecksums =
            client.database.checksums(id:format:timeout:)
        let downloads: (Int?, Duration?) async throws -> [Download] =
            client.database.downloads(limit:timeout:)
        let downloadURL: (String, DatabaseFormat, Duration?) async throws -> URL =
            client.database.downloadURL(id:format:timeout:)

        let toFile: (String, DatabaseFormat, URL) async throws -> Int64 =
            client.database.download(_:format:to:)
        let toSink: (String, DatabaseFormat, DownloadSink) async throws -> Int64 =
            client.database.download(_:format:to:)
        let toBytes: (String, DatabaseFormat) async throws -> Data =
            client.database.downloadBytes(_:format:)

        // One of them is called, so these are live code rather than a comment the
        // compiler happens to check.
        #expect(try await list(.seconds(5)).isEmpty)
        #expect(await stub.callCount == 1)
        _ = (metadata, checksums, downloads, downloadURL, toFile, toSink, toBytes)
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

    // A bound no attempt could meet is an argument mistake and is answered as
    // one. Through 2.2.0 `withDeadline` held a `precondition`, so zero or a
    // negative crashed the caller's process, and a `Duration` past what
    // `Task.sleep` counts to crashed it from inside the concurrency runtime.
    @Test(
        "a timeout no attempt could meet is refused before any request",
        arguments: [
            Duration.zero, .seconds(-1), .milliseconds(-1), .seconds(Int64.max),
            maxTimeout + .seconds(1),
        ],
    )
    func anImpossibleTimeoutIsRefused(_ timeout: Duration) async throws {
        let stub = StubTransport([StubTransport.listPath: .json(["databases": []])])
        let client = InternetDataClient(options: .init(apiKey: "key", retries: 2, transport: stub))

        let failure = await #expect(throws: InternetDataError.self) {
            try await client.database.list(timeout: timeout)
        }
        let error = try #require(failure)

        #expect(error.kind == .badRequest)
        #expect(error.isRetryable == false)
        // Retries are on, so a refusal classified as retryable would show up
        // here as three requests rather than as the wrong kind alone.
        #expect(await stub.callCount == 0, "the request went out before the bound was checked")
    }

    // A check written into one method is a check the other four callers do not
    // get, and they reach `withDeadline` by four separate paths.
    @Test("every call refuses an impossible timeout", arguments: Call.allCases)
    func everyCallRefusesAnImpossibleTimeout(_ call: Call) async throws {
        let stub = StubTransport()
        let client = InternetDataClient(options: .init(apiKey: "key", retries: 0, transport: stub))

        let failure = try await Self.failure(of: call, on: client, timeout: .zero)

        #expect(failure.kind == .badRequest)
        #expect(await stub.callCount == 0)
    }

    static func client(
        _ origin: TestOrigin, retries: Int = 0, timeout: Duration = Self.timeout,
    ) -> InternetDataClient {
        InternetDataClient(
            options: .init(
                apiKey: "key", baseURL: URL(string: "http://127.0.0.1:\(origin.port)")!, retries: retries,
                timeout: timeout,
            ),
        )
    }

    /// `timeout` nil is the call taking the client's, which is what every case
    /// but the per-call one is about.
    static func failure(
        of call: Call, on client: InternetDataClient, timeout: Duration? = nil,
    ) async throws -> InternetDataError {
        let caught = await #expect(throws: InternetDataError.self) {
            switch call {
            case .list:
                _ = try await client.database.list(timeout: timeout)
            case .metadata:
                _ = try await client.database.metadata(id: "bogon_ip_v1", timeout: timeout)
            case .checksums:
                _ = try await client.database.checksums(
                    id: "bogon_ip_v1", format: .csvgz, timeout: timeout,
                )
            case .downloads:
                _ = try await client.database.downloads(timeout: timeout)
            case .downloadURL:
                _ = try await client.database.downloadURL(
                    id: "bogon_ip_v1", format: .csvgz, timeout: timeout,
                )
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
