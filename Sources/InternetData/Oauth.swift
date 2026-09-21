import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Sign a person in with OAuth's device flow.
///
/// Reached as ``InternetDataClient/oauth``. A program on the person's own machine
/// starts a sign-in with ``deviceAuthorization(clientID:scope:resource:timeout:)``,
/// shows them ``DeviceAuthorization/verificationURI`` and
/// ``DeviceAuthorization/userCode``, and waits in
/// ``pollDeviceToken(_:clientID:timeout:)`` while they approve it in a browser.
///
/// No request here carries the client's API key, and none needs one: build the
/// client without a key to sign someone in. A client ID is issued on request
/// through support@internetdata.io.
///
/// Every request goes straight to the transport rather than through the
/// generated client, whose middleware presents the key and classifies an error
/// status before an OAuth body can be read.
public struct OauthAPI: Sendable {
    // An OAuth answer is a small JSON document; this only stops a runaway body.
    private static let maxBodyBytes = 1 << 20
    private static let deviceCodeGrant = "urn:ietf:params:oauth:grant-type:device_code"

    private let transport: any ClientTransport
    private let baseURL: URL
    private let retries: Int
    private let timeout: Duration

    // The poll's wait and its monotonic clock, replaced together by the tests so
    // the deadline reads the same time the waits spent.
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    var now: @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }

    init(transport: any ClientTransport, baseURL: URL, retries: Int, timeout: Duration) {
        self.transport = transport
        // Without a trailing slash already: the client drops every one before
        // handing it over.
        self.baseURL = baseURL
        self.retries = retries
        self.timeout = timeout
    }

    /// The authorization server's metadata document (RFC 8414).
    ///
    /// - Parameter timeout: Overrides the client's ``InternetDataClient/Options/timeout``
    ///   for each attempt of this call.
    public func metadata(timeout: Duration? = nil) async throws -> OauthMetadata {
        try await withRetry(retries) {
            try await withDeadline(timeout ?? self.timeout) {
                try await send(.get, "/.well-known/oauth-authorization-server", form: nil)
            }
        }
    }

    /// Start a device sign-in: the codes to show the person, and the one to poll
    /// with.
    ///
    /// Consumes nothing, so a transient failure is retried like any other call.
    /// Throws ``OauthError/rejected(_:)`` with `slow_down` when this address
    /// starts too many.
    ///
    /// - Parameters:
    ///   - scope: The scopes to request, space-delimited and sent verbatim, such
    ///     as `account.read apikeys.read apikeys.reveal`. The server narrows it
    ///     to what the client may ask for.
    ///   - resource: The RFC 8707 resource the token is meant for.
    ///   - timeout: Overrides the client's timeout for each attempt of this call.
    public func deviceAuthorization(
        clientID: String, scope: String? = nil, resource: String? = nil, timeout: Duration? = nil,
    ) async throws -> DeviceAuthorization {
        var form = [("client_id", clientID)]
        if let scope {
            form.append(("scope", scope))
        }
        if let resource {
            form.append(("resource", resource))
        }
        let fields = form
        return try await withRetry(retries) {
            try await withDeadline(timeout ?? self.timeout) {
                try await send(.post, "/oauth/device_authorization", form: fields)
            }
        }
    }

    /// Exchange an approved device code for tokens, once.
    ///
    /// Never retried: the server spends the code on approval, so a retry after a
    /// lost success loses the tokens. `authorization_pending` and `slow_down`
    /// throw ``OauthError/rejected(_:)``; ``pollDeviceToken(_:clientID:timeout:)``
    /// is the loop around them. ``TokenResponse/apikey`` is the key the person
    /// picked, when its secret can be read back.
    public func exchangeDeviceCode(
        _ deviceCode: String, clientID: String, timeout: Duration? = nil,
    ) async throws -> TokenResponse {
        try await exchange(
            [("grant_type", Self.deviceCodeGrant), ("device_code", deviceCode), ("client_id", clientID)],
            timeout: timeout,
        )
    }

    /// Exchange a refresh token for a new pair, once.
    ///
    /// Never retried: the server spends the refresh token before minting the new
    /// pair, so keep the ``TokenResponse/refreshToken`` this answers. A refresh
    /// names the key (``TokenResponse/apikeyID``) but never reveals it.
    public func exchangeRefreshToken(
        _ refreshToken: String, clientID: String, timeout: Duration? = nil,
    ) async throws -> TokenResponse {
        try await exchange(
            [("grant_type", "refresh_token"), ("refresh_token", refreshToken), ("client_id", clientID)],
            timeout: timeout,
        )
    }

    /// Revoke a token. A refresh token ends the whole sign-in and every token it
    /// issued, which is how a machine signs out.
    ///
    /// The server answers success for any token, known or not, and its body is
    /// never read.
    public func revoke(_ token: String, clientID: String, timeout: Duration? = nil) async throws {
        let fields = [("token", token), ("client_id", clientID)]
        try await withRetry(retries) {
            try await withDeadline(timeout ?? self.timeout) {
                _ = try await respond(.post, "/oauth/revoke", form: fields, readBody: false)
            }
        }
    }

    /// Wait for the person to approve a device sign-in, and answer its tokens.
    ///
    /// Waits ``DeviceAuthorization/interval`` seconds before every poll, the first
    /// included, and five more for the rest of the call after each `slow_down`.
    /// Ends with ``OauthError/accessDenied(_:)`` when the person refuses and with
    /// ``OauthError/expiredToken(_:)`` when the code expires; one with no status
    /// means the code's lifetime, counted from this call, ran out locally.
    ///
    /// Any other failure ends the poll unchanged, and calling again with the same
    /// `device` is safe until it expires. Cancel the task to stop waiting; the
    /// call then throws `CancellationError`.
    ///
    /// - Parameter timeout: Bounds each poll, never the poll as a whole.
    public func pollDeviceToken(
        _ device: DeviceAuthorization, clientID: String, timeout: Duration? = nil,
    ) async throws -> TokenResponse {
        var interval = device.interval >= 1 ? device.interval : 5
        let deadline = now() + .seconds(device.expiresIn)
        while true {
            // Slept AFTER each answer rather than on a ticker: every poll restarts
            // the server's own five second clock, early or not.
            try await sleep(.seconds(interval))
            if now() >= deadline {
                throw OauthError.expiredToken(
                    OauthErrorResponse(errorCode: "expired_token", errorDescription: nil, status: nil),
                )
            }
            do {
                return try await exchangeDeviceCode(device.deviceCode, clientID: clientID, timeout: timeout)
            } catch OauthError.rejected(let refusal) where refusal.errorCode == "authorization_pending" {
                continue
            } catch OauthError.rejected(let refusal) where refusal.errorCode == "slow_down" {
                interval += 5
            }
        }
    }

    private func exchange(_ fields: [(String, String)], timeout: Duration?) async throws -> TokenResponse {
        try await withRetry(0) {
            try await withDeadline(timeout ?? self.timeout) {
                try await send(.post, "/oauth/token", form: fields)
            }
        }
    }

    private func send<T: Decodable & Sendable>(
        _ method: HTTPRequest.Method, _ path: String, form: [(String, String)]?,
    ) async throws -> T {
        let (status, body) = try await respond(method, path, form: form, readBody: true)
        do {
            return try JSONDecoder().decode(T.self, from: Data(body))
        } catch {
            // A 2xx that does not parse, or lacks a member the type always carries,
            // is the server failing rather than a refusal.
            throw InternetDataError(
                kind: .serverError,
                message: "the authorization server answered \(status) without a valid \(T.self)",
                status: status,
            )
        }
    }

    private func respond(
        _ method: HTTPRequest.Method, _ path: String, form: [(String, String)]?, readBody: Bool,
    ) async throws -> (status: Int, body: ArraySlice<UInt8>) {
        var fields = HTTPFields()
        fields[.accept] = "application/json"
        var body: HTTPBody?
        if let form {
            fields[.contentType] = "application/x-www-form-urlencoded"
            body = HTTPBody(formEncoded(form))
        }
        let (response, responseBody) = try await transport.send(
            HTTPRequest(method: method, scheme: nil, authority: nil, path: path, headerFields: fields),
            body: body,
            baseURL: baseURL,
            operationID: "oauth",
        )
        let status = Int(response.status.code)
        guard (200..<300).contains(status) else {
            let collected = (try? await ArraySlice(
                collecting: responseBody ?? HTTPBody(), upTo: Self.maxBodyBytes,
            )) ?? []
            if (400..<500).contains(status), let refusal = OauthError(status: status, body: collected) {
                throw refusal
            }
            throw InternetDataError.from(status: status, headers: response.headerFields, body: collected)
        }
        guard readBody else {
            return (status, [])
        }
        return (status, try await ArraySlice(collecting: responseBody ?? HTTPBody(), upTo: Self.maxBodyBytes))
    }
}

/// The authorization server refused an OAuth request: an answer in the 4xx range
/// whose body names an RFC 6749 error code.
///
/// Never retryable, and never retried by the library. `access_denied` and
/// `expired_token` have their own cases; every other code, including one the
/// library has never seen, is ``rejected(_:)``. Anything else that goes wrong is
/// a ``InternetDataError``.
public enum OauthError: Error, Sendable, Hashable {
    /// The person refused the sign-in. The device code is spent.
    case accessDenied(OauthErrorResponse)
    /// The device code is no longer valid: it expired, or it was already
    /// exchanged or refused. A `nil` status means the poll ran past the code's
    /// lifetime without asking the server.
    case expiredToken(OauthErrorResponse)
    /// Any other refusal, such as `invalid_grant`, `slow_down`, or `invalid_client`
    /// (status 401) for a client ID that is not registered.
    case rejected(OauthErrorResponse)

    init?(status: Int, body: ArraySlice<UInt8>) {
        guard case .object(let members)? = try? JSONDecoder().decode(JSONValue.self, from: Data(body)),
            case .string(let code)? = members["error"]
        else {
            return nil
        }
        let response = OauthErrorResponse(
            errorCode: code, errorDescription: members["error_description"]?.stringValue, status: status,
        )
        switch code {
        case "access_denied": self = .accessDenied(response)
        case "expired_token": self = .expiredToken(response)
        default: self = .rejected(response)
        }
    }

    var response: OauthErrorResponse {
        switch self {
        case .accessDenied(let response), .expiredToken(let response), .rejected(let response):
            return response
        }
    }
}

/// What an authorization server said when it refused.
public struct OauthErrorResponse: Sendable, Hashable {
    /// The RFC 6749 `error`, such as `invalid_grant` or `slow_down`.
    public let errorCode: String
    /// The server's `error_description`, when it sent one as a string.
    public let errorDescription: String?
    /// The HTTP status, or `nil` for an expiry the poll decided locally.
    public let status: Int?
}

extension OauthError: CustomStringConvertible {
    public var description: String {
        response.errorDescription.map { "\(response.errorCode): \($0)" } ?? response.errorCode
    }
}

extension OauthError: LocalizedError {
    public var errorDescription: String? { description }
}

/// The authorization server's metadata document (RFC 8414).
public struct OauthMetadata: Sendable, Hashable, Codable {
    public let issuer: String
    public let authorizationEndpoint: String
    public let tokenEndpoint: String
    public let deviceAuthorizationEndpoint: String?
    public let revocationEndpoint: String?
    public let scopesSupported: [String]?
    public let responseTypesSupported: [String]?
    public let grantTypesSupported: [String]?
    public let codeChallengeMethodsSupported: [String]?
    public let tokenEndpointAuthMethodsSupported: [String]?
    public let authorizationResponseIssParameterSupported: Bool?
    public let serviceDocumentation: String?

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case deviceAuthorizationEndpoint = "device_authorization_endpoint"
        case revocationEndpoint = "revocation_endpoint"
        case scopesSupported = "scopes_supported"
        case responseTypesSupported = "response_types_supported"
        case grantTypesSupported = "grant_types_supported"
        case codeChallengeMethodsSupported = "code_challenge_methods_supported"
        case tokenEndpointAuthMethodsSupported = "token_endpoint_auth_methods_supported"
        case authorizationResponseIssParameterSupported = "authorization_response_iss_parameter_supported"
        case serviceDocumentation = "service_documentation"
    }
}

/// A started device sign-in.
///
/// `Codable`, so a program can keep one across a restart and still hand it to
/// ``OauthAPI/pollDeviceToken(_:clientID:timeout:)``.
public struct DeviceAuthorization: Sendable, Hashable, Codable {
    /// The code to poll with. Never show it.
    public let deviceCode: String
    /// The code the person types at ``verificationURI``.
    public let userCode: String
    public let verificationURI: String
    /// The same page with the code already filled in.
    public let verificationURIComplete: String?
    /// Seconds until both codes expire.
    public let expiresIn: Int
    /// Seconds between polls.
    public let interval: Int

    public init(
        deviceCode: String, userCode: String, verificationURI: String,
        verificationURIComplete: String? = nil, expiresIn: Int, interval: Int,
    ) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURI = verificationURI
        self.verificationURIComplete = verificationURIComplete
        self.expiresIn = expiresIn
        self.interval = interval
    }

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case verificationURIComplete = "verification_uri_complete"
        case expiresIn = "expires_in"
        case interval
    }
}

/// The tokens a sign-in or a refresh answers.
public struct TokenResponse: Sendable, Hashable, Codable {
    public let accessToken: String
    /// Always `Bearer`.
    public let tokenType: String
    /// Seconds until the access token expires.
    public let expiresIn: Int
    /// A refresh consumes the token it presents, so keep this one.
    public let refreshToken: String?
    /// What was actually granted, which may be narrower than what was asked for.
    /// An empty string is a grant of nothing, not an absent member.
    public let scope: String?
    /// The ID of the API key the person picked, while this sign-in may still read
    /// that key back.
    public let apikeyID: String?
    /// The API key itself. Only a device code exchange returns it, and only when
    /// the key's secret can be read back.
    public let apikey: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
        case apikeyID = "mslm:apikey_id"
        case apikey = "mslm:apikey"
    }
}

// Only RFC 3986's unreserved characters stay literal, so a `+` in a token travels
// as %2B instead of reading as a space.
private let formSafe = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~",
)

private func formEncoded(_ fields: [(String, String)]) -> [UInt8] {
    let pairs = fields.map { name, value in
        "\(name.addingPercentEncoding(withAllowedCharacters: formSafe) ?? name)="
            + (value.addingPercentEncoding(withAllowedCharacters: formSafe) ?? value)
    }
    return Array(pairs.joined(separator: "&").utf8)
}
