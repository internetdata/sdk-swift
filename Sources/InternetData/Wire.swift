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

/// Reads an RFC 3339 `date-time`, and nothing else.
///
/// The runtime ships two ISO 8601 transcoders and each refuses what the other
/// accepts: `.iso8601` refuses `2026-09-04T18:04:26.431Z`, which is what a
/// license term and a download's `created` are served as, and
/// `.iso8601WithFractionalSeconds` refuses the same without its fraction. Both
/// also take what RFC 3339 does not: on Linux, 30 February as 2 March, `24:00`
/// as the next day, `+0500`, `+05` and `UTC` as zones, and `+24:00` as two
/// hours. A value that is no `date-time` fails the call like any other answer
/// it cannot read.
struct RFC3339DateTranscoder: DateTranscoder {
    private let fractional: any DateTranscoder = .iso8601WithFractionalSeconds

    func encode(_ date: Date) throws -> String {
        try fractional.encode(date)
    }

    func decode(_ string: String) throws -> Date {
        guard let date = RFC3339.dateTime(string) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "\(string.debugDescription) is not an RFC 3339 date-time"),
            )
        }
        return date
    }
}

/// RFC 3339's `date-time` and `full-date`, read by position.
enum RFC3339 {
    /// `2026-10-05T07:49:45Z`: any fraction of a second, then `Z` or an offset
    /// `+hh:mm` or `-hh:mm`, with `T` and `Z` in either case. A leap second is
    /// refused, since a `Date` cannot hold one.
    static func dateTime(_ text: String) -> Date? {
        let c = Array(text.utf8)
        guard c.count >= 20, let days = fullDate(c[0..<10]), c[10] == ascii("T") || c[10] == ascii("t"),
            c[13] == ascii(":"), c[16] == ascii(":"),
            let hour = digits(c[11..<13]), let minute = digits(c[14..<16]), let second = digits(c[17..<19]),
            hour <= 23, minute <= 59, second <= 59
        else {
            return nil
        }
        var i = 19
        var fraction = 0.0
        if c[i] == ascii(".") {
            let end = c[(i + 1)...].firstIndex(where: { !isDigit($0) }) ?? c.endIndex
            guard end > i + 1, let value = Double("0." + String(decoding: c[(i + 1)..<end], as: UTF8.self)) else {
                return nil
            }
            fraction = value
            i = end
        }
        guard i < c.count else {
            return nil
        }
        var offset: Int64 = 0
        if c[i] == ascii("Z") || c[i] == ascii("z") {
            guard i + 1 == c.count else {
                return nil
            }
        } else {
            guard c[i] == ascii("+") || c[i] == ascii("-"), c.count == i + 6, c[i + 3] == ascii(":"),
                let hours = digits(c[(i + 1)..<(i + 3)]), let minutes = digits(c[(i + 4)..<(i + 6)]),
                hours <= 23, minutes <= 59
            else {
                return nil
            }
            offset = (hours * 60 + minutes) * 60 * (c[i] == ascii("-") ? -1 : 1)
        }
        // From the reference date rather than 1970, so a fraction lands on the
        // same `Date` the runtime's own transcoders produced.
        let seconds = days * 86_400 + hour * 3_600 + minute * 60 + second - offset - 978_307_200
        return Date(timeIntervalSinceReferenceDate: Double(seconds) + fraction)
    }

    /// `2026-10-05`, on a day its month has.
    static func isFullDate(_ text: String) -> Bool {
        let c = Array(text.utf8)
        return c.count == 10 && fullDate(c[0..<10]) != nil
    }

    // Days from 1970-01-01 to a `full-date`.
    private static func fullDate(_ c: ArraySlice<UInt8>) -> Int64? {
        let s = c.startIndex
        guard c.count == 10, c[s + 4] == ascii("-"), c[s + 7] == ascii("-"),
            let year = digits(c[s..<(s + 4)]), let month = digits(c[(s + 5)..<(s + 7)]),
            let day = digits(c[(s + 8)..<(s + 10)])
        else {
            return nil
        }
        return daysSinceEpoch(year: year, month: month, day: day)
    }

    private static func digits(_ c: ArraySlice<UInt8>) -> Int64? {
        guard !c.isEmpty, c.allSatisfy(isDigit) else {
            return nil
        }
        return c.reduce(0) { $0 * 10 + Int64($1 - ascii("0")) }
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= ascii("0") && byte <= ascii("9")
    }

    private static func ascii(_ scalar: Unicode.Scalar) -> UInt8 {
        UInt8(ascii: scalar)
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
        // HTTPTypes turns a control character into a space, so such a key went
        // out as another key. Refused before anything is sent, because the
        // client's initializer cannot throw.
        if apiKey.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            throw InternetDataError(kind: .badRequest, message: "the API key holds a control character")
        }
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
            // `Retry-After` is the server's number. Slept as given, `2147484`
            // held a call 24.8 days and a year-9999 date for good, while one past
            // `maxTimeout` never ended or trapped: `9223372036854775807` crashed
            // the caller's process. One past ``maxRetryAfter`` is waited out on
            // the client's own backoff instead; the 429 is still a throttle, and
            // the error keeps the value the server sent.
            let asked = failure.retryAfter.flatMap { $0 <= maxRetryAfter ? $0 : nil }
            try await Task.sleep(for: asked ?? backoff(attempt))
            attempt += 1
        }
    }
}

private func backoff(_ attempt: Int) -> Duration {
    .milliseconds(min(5_000, 200 << min(attempt, 5)))
}

/// The longest `Retry-After` ``withRetry(_:_:)`` will wait out: 2^31 - 1
/// milliseconds, about 24.8 days, the bound every client of this API keeps.
let maxRetryAfter: Duration = .milliseconds(Int64(Int32.max))

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

/// Refuses a per-call bound no attempt could meet, as ``InternetDataErrorKind/badRequest``.
///
/// Refused rather than trapped: a `precondition` crashes a caller's process over
/// an argument it could have been handed back. Same shape as a per-call
/// `concurrency` below 1 in the sibling client.
func checkTimeout(_ timeout: Duration) throws {
    guard timeout > .zero, timeout <= maxTimeout else {
        throw InternetDataError(
            kind: .badRequest,
            message: "timeout must be positive and at most \(maxTimeout), got \(timeout)",
        )
    }
}

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
    try checkTimeout(timeout)
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
