import AsyncHTTPClient
import Foundation
import HTTPTypes
import OpenAPIAsyncHTTPClient
import OpenAPIRuntime

/// The transport used when ``InternetDataClient/Options/transport`` is left unset.
///
/// One `HTTPClient` for the whole process, held in a global so it is never
/// deallocated. That matters: AsyncHTTPClient's `deinit` traps in debug builds
/// when a client was not shut down, and an SDK whose first README line is
/// `InternetDataClient(apiKey:)` must not impose a shutdown contract on its
/// caller. This is the model `HTTPClient.shared` already uses, with one
/// difference that is the whole reason we do not simply use it: **redirects are
/// refused**.
///
/// The download endpoint answers `302` to object storage, and a transport that
/// follows the redirect reads a database that routinely runs to gigabytes into
/// memory. `.disallow` is one value rather than a delegate to get right, and it
/// behaves identically on Linux and on Apple platforms.
///
/// Its own deadline is pushed out of the way. It stops at the response head, and
/// at its default of a minute it would cut short a client whose own
/// ``InternetDataClient/Options/timeout`` is longer; the library's per-attempt
/// bound is the one that fires.
enum DefaultTransport {
    static let shared: any ClientTransport = AsyncHTTPClientTransport(
        configuration: .init(client: httpClient, timeout: .hours(24 * 365)),
    )

    private static let httpClient = HTTPClient(
        eventLoopGroupProvider: .singleton,
        configuration: HTTPClient.Configuration(redirectConfiguration: .disallow),
    )
}

/// Reads an RFC 3339 timestamp whether or not it carries fractional seconds.
///
/// The runtime ships two transcoders and each rejects what the other accepts:
/// `.iso8601` refuses `2026-09-04T18:04:26.431Z`, which is what a license term
/// and a download's `created` are served as, and `.iso8601WithFractionalSeconds`
/// refuses `2026-09-04T18:04:26Z`, which is what a service with a different JSON
/// encoder behind the same host would send. Both are valid RFC 3339, so both are
/// read. Only the decode side has to be forgiving; nothing here ever encodes a
/// date.
///
/// No fixture can catch this. The spec says `format: date-time` and nothing
/// more, so a stub written from it round-trips through whichever transcoder the
/// suite happens to pick; the first LIVE call is what fails.
struct LenientDateTranscoder: DateTranscoder {
    private let fractional: any DateTranscoder = .iso8601WithFractionalSeconds
    private let whole: any DateTranscoder = .iso8601

    func encode(_ date: Date) throws -> String {
        try fractional.encode(date)
    }

    func decode(_ string: String) throws -> Date {
        guard let date = try? fractional.decode(string) else {
            return try whole.decode(string)
        }
        return date
    }
}

/// Turns every non-2xx answer into an ``InternetDataError`` before the generated
/// client can decode it.
///
/// Classifying here rather than over the generated per-status output cases is
/// what makes the range rule enforceable: a status this API does not document
/// today arrives with its real number rather than as an `undocumented` case that
/// has to be re-derived.
struct ErrorMiddleware: ClientMiddleware {
    // Enough for an error envelope from the API or from an intermediary, and
    // small enough that a runaway body cannot be used to exhaust memory.
    private static let maxErrorBodyBytes = 64 * 1024

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?),
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let (response, responseBody) = try await next(request, body, baseURL)
        let status = response.status.code

        // A success here means the transport followed the 302 and is holding the
        // database itself. Refused before the body is touched, which is what
        // stops a caller-supplied transport from streaming gigabytes into RAM.
        if operationID == "downloadDatabaseV2", (200..<300).contains(status) {
            throw InternetDataError(
                kind: .serverError,
                message: "the download endpoint answered \(status) rather than a redirect, which"
                    + " means the transport followed it; supply a transport that does not",
                status: Int(status),
            )
        }
        guard status >= 400 else {
            return (response, responseBody)
        }
        let collected = try? await ArraySlice(
            collecting: responseBody ?? HTTPBody(), upTo: Self.maxErrorBodyBytes,
        )
        throw InternetDataError.from(
            status: Int(status), headers: response.headerFields, body: collected ?? [],
        )
    }
}

/// Presents the API key.
///
/// `Authorization: Bearer` is the only scheme the v2 endpoints accept. The
/// legacy v1 `?apikey=` credential put the key in a query string, where it lands
/// in every access log between here and the origin.
struct AuthMiddleware: ClientMiddleware {
    let apiKey: String

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?),
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        request.headerFields[.authorization] = "Bearer \(apiKey)"
        return try await next(request, body, baseURL)
    }
}

/// Runs an operation, retrying only what is worth retrying.
///
/// A `429` carrying `Retry-After` is a transient rate limit and the header is
/// the wait; a `429` without one is a spent allowance, and retrying it hammers a
/// quota that will not recover until its window rolls over. Everything else in
/// the 4xx range is a client error and is never retried.
func withRetry<T>(_ retries: Int, _ operation: () async throws -> T) async throws -> T {
    var attempt = 0
    while true {
        do {
            return try await operation()
        } catch {
            // A cancelled task must not be retried, and the failure it reports
            // is the cancellation rather than whatever the transport made of
            // it. Checking the task is more robust than matching on an error
            // type the transport may have wrapped or renamed.
            try Task.checkCancellation()
            // An authorization server's refusal is final, and wrapping it would
            // turn it into a retryable network error.
            if error is OauthError {
                throw error
            }
            let failure = InternetDataError.wrapping(error)
            guard attempt < retries, failure.isRetryable else {
                throw failure
            }
            try await Task.sleep(for: failure.retryAfter ?? backoff(attempt))
            attempt += 1
        }
    }
}

private func backoff(_ attempt: Int) -> Duration {
    .milliseconds(min(5_000, 200 << min(attempt, 5)))
}

/// The longest bound ``withDeadline(_:_:)`` can be given.
///
/// `Task.sleep(for:)` turns the deadline - now PLUS the bound - into whole
/// seconds in an `Int64`, and one that does not fit TRAPS inside the concurrency
/// runtime with `Fatal error: Not enough bits to represent the passed value`,
/// which no caller and no test can handle. Measured on Swift 6.3, Linux,
/// 2026-09-20: `.seconds(Int64.max)` and `.seconds(Int64.max - 1)` both crash
/// the process, while `.seconds(Int64.max / 2)` and `.seconds(8e18)` are slept
/// on happily, because what has to fit alongside the bound is the monotonic
/// clock's own reading. Half the range is refused rather than the exact
/// headroom, which moves as the machine runs; the ~146 billion years left over
/// are past anything a caller means by a timeout.
let maxTimeout: Duration = .seconds(Int64.max / 2)

/// Bounds one attempt with a deadline the library owns.
///
/// Raced rather than left to cancellation: cancelling the attempt releases its
/// connection, but only a transport that HONORS cancellation then returns, and
/// one supplied through ``InternetDataClient/Options/transport`` need not. So
/// the caller is answered at the deadline, and the attempt is cancelled and
/// left to finish on its own.
func withDeadline<T: Sendable>(
    _ timeout: Duration, _ operation: @escaping @Sendable () async throws -> T,
) async throws -> T {
    // Refused rather than trapped: this is the one place a per-call value is
    // seen, and a `precondition` here crashes a caller's process over an
    // argument it could have been handed back. Same shape as a per-call
    // `concurrency` below 1 in the sibling client.
    guard timeout > .zero, timeout <= maxTimeout else {
        throw InternetDataError(
            kind: .badRequest,
            message: "timeout must be positive and at most \(maxTimeout), got \(timeout)",
        )
    }
    let race = Race<T>()
    let attempt = Task {
        do {
            race.settle(.success(try await operation()))
        } catch {
            race.settle(.failure(error))
        }
    }
    let timer = Task {
        try await Task.sleep(for: timeout)
        race.settle(.failure(InternetDataError(
            kind: .network, message: "the request timed out after \(timeout)",
        )))
    }
    defer {
        attempt.cancel()
        timer.cancel()
    }
    return try await withTaskCancellationHandler {
        try await race.value
    } onCancel: {
        race.settle(.failure(CancellationError()))
    }
}

/// An outcome decided once, by whichever side of a race gets there first.
///
/// A lock rather than an actor, because the cancellation handler that settles
/// it is synchronous and cannot wait for one.
private final class Race<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Result<T, any Error>?
    private var waiter: CheckedContinuation<T, any Error>?

    var value: T {
        get async throws {
            try await withCheckedThrowingContinuation { continuation in
                let decided: Result<T, any Error>? = lock.withLock {
                    if outcome == nil {
                        waiter = continuation
                    }
                    return outcome
                }
                if let decided {
                    continuation.resume(with: decided)
                }
            }
        }
    }

    func settle(_ result: Result<T, any Error>) {
        let waiting: CheckedContinuation<T, any Error>? = lock.withLock {
            guard outcome == nil else {
                return nil
            }
            outcome = result
            let waiting = waiter
            waiter = nil
            return waiting
        }
        waiting?.resume(with: result)
    }
}
