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
    /// The generated client wraps whatever the transport, a middleware or its
    /// own decoding threw in `ClientError`, so the error this library raised has
    /// to be dug back out of `underlyingError` before it can be classified. A
    /// `ClientError` carrying a 2xx response failed while that answer was being
    /// read - a proxy's HTML page, a cut-off or empty body, one without a member
    /// the answer requires - which is the server's fault rather than the
    /// network's: a server error carrying the status, retried like a 5xx.
    static func wrapping(_ error: any Error) -> InternetDataError {
        if let ours = error as? InternetDataError {
            return ours
        }
        if let client = error as? ClientError {
            if let ours = client.underlyingError as? InternetDataError {
                return ours
            }
            if let status = client.response.map({ Int($0.status.code) }), (200..<300).contains(status) {
                return InternetDataError(
                    kind: .serverError, message: "the response was not the answer this call returns",
                    status: status,
                )
            }
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
    // An empty code says nothing, so it gives way to the fallback.
    return envelope.rc.flatMap { $0.isEmpty ? nil : $0 }
}

private struct ErrorEnvelope: Decodable {
    let rc: String?
}

/// Reads `Retry-After` as RFC 9110 defines it: a count of seconds written as
/// digits alone, or an HTTP date in one of its three forms, read as GMT.
///
/// Anything else - a sign, a fraction, a word, a zone other than GMT, a date
/// naming a day that does not exist - is no wait at all, and so is a count past
/// `Int.max`, which makes its 429 a spent allowance rather than a throttle.
func parseRetryAfter(_ value: String?) -> Duration? {
    guard let text = value?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
        return nil
    }
    if text.utf8.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) {
        return Int(text).map { .seconds($0) }
    }
    guard let when = HTTPDate.epochSeconds(text) else {
        return nil
    }
    return .seconds(max(0, (Double(when) - Date().timeIntervalSince1970).rounded(.up)))
}

/// RFC 9110's three date forms, each in GMT:
///
///     Sun, 06 Nov 1994 08:49:37 GMT    IMF-fixdate, the one a server must send
///     Sunday, 06-Nov-94 08:49:37 GMT   RFC 850
///     Sun Nov  6 08:49:37 1994         asctime
///
/// Parsed by position rather than through `DateFormatter`, whose patterns read
/// one form each, take any zone it can name, and leave whether 31 Nov is 1 Dec
/// to the platform.
enum HTTPDate {
    static func epochSeconds(_ text: String) -> Int64? {
        let chars = Array(text.utf8)
        return imfFixdate(chars) ?? rfc850(chars) ?? asctime(chars)
    }

    private static let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    private static let longDays = [
        "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
    ]
    private static let months = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]

    private static func imfFixdate(_ c: [UInt8]) -> Int64? {
        guard c.count == 29, days.contains(text(c[0..<3])), text(c[3..<5]) == ", ",
            c[7] == UInt8(ascii: " "), c[11] == UInt8(ascii: " "), c[16] == UInt8(ascii: " "),
            text(c[25..<29]) == " GMT",
            let day = number(c[5..<7]), let year = number(c[12..<16])
        else {
            return nil
        }
        return epoch(year: year, month: month(c[8..<11]), day: day, time: c[17..<25])
    }

    private static func rfc850(_ c: [UInt8]) -> Int64? {
        guard let comma = c.firstIndex(of: UInt8(ascii: ",")), longDays.contains(text(c[..<comma])) else {
            return nil
        }
        let rest = Array(c[(comma + 1)...])
        guard rest.count == 23, rest[0] == UInt8(ascii: " "), rest[3] == UInt8(ascii: "-"),
            rest[7] == UInt8(ascii: "-"), rest[10] == UInt8(ascii: " "), text(rest[19..<23]) == " GMT",
            let day = number(rest[1..<3]), let twoDigits = number(rest[8..<10])
        else {
            return nil
        }
        // A two-digit year more than 50 years ahead is the most recent past year
        // ending in the same digits, as RFC 9110 requires of a recipient.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT") ?? calendar.timeZone
        let now = calendar.component(.year, from: Date())
        var year = now / 100 * 100 + Int(twoDigits)
        if year > now + 50 {
            year -= 100
        }
        return epoch(year: Int64(year), month: month(rest[4..<7]), day: day, time: rest[11..<19])
    }

    private static func asctime(_ c: [UInt8]) -> Int64? {
        guard c.count == 24, days.contains(text(c[0..<3])), c[3] == UInt8(ascii: " "),
            c[7] == UInt8(ascii: " "), c[10] == UInt8(ascii: " "), c[19] == UInt8(ascii: " "),
            // The day is two digits, or a space and one digit.
            let day = c[8] == UInt8(ascii: " ") ? number(c[9..<10]) : number(c[8..<10]),
            let year = number(c[20..<24])
        else {
            return nil
        }
        return epoch(year: year, month: month(c[4..<7]), day: day, time: c[11..<19])
    }

    // Seconds since 1970 for a proleptic Gregorian date and an `HH:MM:SS` time,
    // or nil when either names a moment that does not exist.
    private static func epoch(year: Int64, month: Int64?, day: Int64, time: ArraySlice<UInt8>) -> Int64? {
        let t = Array(time)
        guard let month, t.count == 8, t[2] == UInt8(ascii: ":"), t[5] == UInt8(ascii: ":"),
            let hour = number(t[0..<2]), let minute = number(t[3..<5]), let second = number(t[6..<8]),
            let days = daysSinceEpoch(year: year, month: month, day: day), hour <= 23, minute <= 59, second <= 59
        else {
            return nil
        }
        return days * 86_400 + hour * 3_600 + minute * 60 + second
    }

    private static func month(_ c: ArraySlice<UInt8>) -> Int64? {
        months.firstIndex(of: text(c)).map { Int64($0) + 1 }
    }

    private static func number(_ c: ArraySlice<UInt8>) -> Int64? {
        guard !c.isEmpty, c.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) else {
            return nil
        }
        return Int64(text(c))
    }

    private static func text(_ c: ArraySlice<UInt8>) -> String {
        String(decoding: c, as: UTF8.self)
    }
}

/// Days from 1970-01-01 to a proleptic Gregorian date, or nil for a day its
/// month does not have.
func daysSinceEpoch(year: Int64, month: Int64, day: Int64) -> Int64? {
    guard month >= 1, month <= 12, day >= 1, day <= daysIn(month, of: year) else {
        return nil
    }
    // Counting years from March, so the leap day is last.
    let y = month <= 2 ? year - 1 : year
    let era = (y >= 0 ? y : y - 399) / 400
    let yearOfEra = y - era * 400
    let dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return era * 146_097 + dayOfEra - 719_468
}

private func daysIn(_ month: Int64, of year: Int64) -> Int64 {
    switch month {
    case 2: year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28
    case 4, 6, 9, 11: 30
    default: 31
    }
}
