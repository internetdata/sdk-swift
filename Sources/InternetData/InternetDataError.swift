import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Every failure the library reports.
///
/// `retryAfter` is set only for ``InternetDataErrorKind/rateLimited``, and it is
/// the wait the API asked for rather than one the library invented.
public struct InternetDataError: Error, Sendable, Hashable {
    public let kind: InternetDataErrorKind
    /// The API's `rc` when it sent one, so a refusal says which refusal it is.
    public let message: String
    /// The HTTP status, or `nil` when the request never got an answer.
    public let status: Int?
    /// The server-supplied wait, taken from `Retry-After`.
    public let retryAfter: Duration?

    /// Whether retrying this exact request could succeed.
    public var isRetryable: Bool {
        kind == .rateLimited || kind == .serverError || kind == .network
    }

    public init(
        kind: InternetDataErrorKind, message: String,
        status: Int? = nil, retryAfter: Duration? = nil,
    ) {
        self.kind = kind
        self.message = message
        self.status = status
        self.retryAfter = retryAfter
    }
}

/// Why a request failed.
///
/// ``rateLimited`` and ``quotaExceeded`` both arrive as HTTP 429 and are NOT the
/// same thing. A rate limit is the API protecting itself and carries
/// `Retry-After`; retrying works. A spent quota carries no such header and
/// retrying will not help until the window rolls over or the limit is raised.
/// The header is the only thing that distinguishes them.
public enum InternetDataErrorKind: String, Sendable, Hashable, CaseIterable {
    case badRequest = "bad_request"
    case unauthorized = "unauthorized"
    case forbidden = "forbidden"
    case rateLimited = "rate_limited"
    case quotaExceeded = "quota_exceeded"
    case serverError = "server_error"
    case network = "network"
}

extension InternetDataError: CustomStringConvertible {
    public var description: String {
        status.map { "\(kind.rawValue) (HTTP \($0)): \(message)" } ?? "\(kind.rawValue): \(message)"
    }
}

extension InternetDataError: LocalizedError {
    public var errorDescription: String? { description }
}

extension InternetDataError {
    /// Classifies a non-2xx answer.
    ///
    /// The decision is made on the STATUS RANGE, never on an enumerated list of
    /// the statuses this API happens to document today. Mapping 400/401/403/429
    /// and letting the rest fall through to the `serverError` default is the
    /// easy mistake, and it makes the 404 an unknown database id earns
    /// retryable.
    ///
    /// - Parameter fallback: What to say when the answer carried no envelope,
    ///   for a caller such as object storage whose failures never do.
    static func from(
        status: Int, headers: HTTPFields, body: ArraySlice<UInt8>, fallback: String? = nil,
    ) -> InternetDataError {
        let message = messageOf(body) ?? fallback ?? "request failed with status \(status)"
        let retryAfter = parseRetryAfter(headers[.retryAfter])

        if status == 429 {
            // Present means transient, absent means an allowance is spent.
            // Nothing else in the response separates the two.
            guard let retryAfter else {
                return InternetDataError(kind: .quotaExceeded, message: message, status: status)
            }
            return InternetDataError(
                kind: .rateLimited, message: message, status: status, retryAfter: retryAfter,
            )
        }
        if status >= 500 {
            return InternetDataError(kind: .serverError, message: message, status: status)
        }
        switch status {
        case 401: return InternetDataError(kind: .unauthorized, message: message, status: status)
        case 403: return InternetDataError(kind: .forbidden, message: message, status: status)
        default: return InternetDataError(kind: .badRequest, message: message, status: status)
        }
    }

    /// Reduces anything thrown beneath the idiomatic layer to one error type.
    ///
    /// The generated client wraps whatever the transport or a middleware threw
    /// in `ClientError`, so the error this library raised has to be dug back out
    /// of `underlyingError` before it can be classified.
    static func wrapping(_ error: any Error) -> InternetDataError {
        if let ours = error as? InternetDataError {
            return ours
        }
        if let client = error as? ClientError {
            return wrapping(client.underlyingError)
        }
        return InternetDataError(kind: .network, message: "\(error)")
    }
}

// Every refusal this API sends carries `{"rc": "..."}`, and `rc` is deliberately
// not an enum on the wire so a code added later stays parseable. It is read as
// the message rather than mapped, because the classification comes from the
// status and a caller who wants the exact code has it in `message`.
private func messageOf(_ body: ArraySlice<UInt8>) -> String? {
    guard !body.isEmpty,
        let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: Data(body))
    else {
        return nil
    }
    return envelope.rc
}

private struct ErrorEnvelope: Decodable {
    let rc: String?
}

// The header is documented as an integer count of seconds, but RFC 9110 also
// permits an HTTP date and an intermediary may send one, so both are read.
private func parseRetryAfter(_ value: String?) -> Duration? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else {
        return nil
    }
    if let seconds = Int(trimmed), seconds >= 0 {
        return .seconds(seconds)
    }
    guard let when = httpDateFormatter.date(from: trimmed) else {
        return nil
    }
    return .seconds(max(0, Int(when.timeIntervalSinceNow.rounded(.up))))
}

private let httpDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter
}()
