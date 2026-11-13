import Foundation
import HTTPTypes
import OpenAPIRuntime

/// A client for the InternetData API.
///
/// A `struct` rather than an `actor`: the only mutable state is the answer cache,
/// which is isolated inside its own actor, so the client itself is immutable and
/// `Sendable` and its methods run on whatever executor called them. Making the
/// whole client an actor would serialize every entry and exit for no benefit.
///
/// The cache is per instance, so an answer is never shared between two clients
/// holding different API keys and therefore entitled to different fields.
///
/// The database calls live under ``database`` and the OAuth sign-in under
/// ``oauth``. The second level is there because the sibling VPNDetection client
/// spells the same calls the same way, and a codebase holding both should not
/// have to remember which one is flat.
public struct InternetDataClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://api.internetdata.io")!

    /// The most addresses `POST /batch` takes in one call; a larger batch is
    /// sent in chunks of this size.
    static let batchMax = 1000

    /// The licensed database downloads, for keys that carry the `db.download` scope.
    public let database: DatabaseAPI

    /// Sign a person in with OAuth's device flow and receive one of their API
    /// keys. Its requests never carry this client's key.
    public let oauth: OauthAPI

    private let api: Client
    // What the batch sends through on its own, since it reads its answer entry by
    // entry rather than through the generated decoder.
    private let transport: any ClientTransport
    private let baseURL: URL
    private let middlewares: [any ClientMiddleware]
    private let cache: ResultCache?
    private let concurrency: Int
    private let retries: Int
    private let timeout: Duration

    public init(options: Options = Options()) {
        precondition(options.concurrency > 0, "concurrency must be positive")
        precondition(options.retries >= 0, "retries cannot be negative")
        precondition(options.timeout > .zero, "timeout must be positive")
        precondition(options.timeout <= maxTimeout, "timeout is longer than the runtime can count")

        // Attached only when there is a key, so a keyless client sends no
        // `Authorization` header rather than `Bearer ` with nothing behind it -
        // which is what an unset `${{ secrets.X }}` interpolates to, and which
        // the API answers 401 to rather than treating as no credential at all.
        // Trimmed, so a key read from a file loses its newline, and blanks alone
        // are no key.
        var middlewares: [any ClientMiddleware] = []
        if let apiKey = options.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), apiKey.isEmpty == false {
            middlewares.append(AuthMiddleware(apiKey: apiKey))
        }
        middlewares.append(ErrorMiddleware())

        // Resolved once, because the download path calls object storage straight
        // through the transport rather than through the generated client and has
        // to reach the same implementation a caller substituted.
        let transport = options.transport ?? DefaultTransport.shared
        let baseURL = withoutTrailingSlashes(options.baseURL)
        let api = Client(
            serverURL: baseURL,
            configuration: Configuration(dateTranscoder: RFC3339DateTranscoder()),
            transport: transport,
            middlewares: middlewares,
        )
        self.api = api
        self.transport = transport
        self.baseURL = baseURL
        self.middlewares = middlewares
        self.cache = options.cache.map(ResultCache.init)
        self.concurrency = options.concurrency
        self.retries = options.retries
        self.timeout = options.timeout
        self.database = DatabaseAPI(
            api: api, transport: transport, retries: options.retries, timeout: options.timeout,
        )
        self.oauth = OauthAPI(
            transport: transport, baseURL: authorizationServer(of: baseURL), retries: options.retries,
            timeout: options.timeout,
        )
    }

    /// A client that presents `apiKey` and takes every other default.
    public init(apiKey: String) {
        self.init(options: Options(apiKey: apiKey))
    }

    /// Whether an address is private, loopback, link-local, documentation,
    /// multicast or otherwise not routable, including the IPv6 equivalents and
    /// the 6to4 and Teredo ranges.
    ///
    /// These are the addresses ``lookup(_:retries:timeout:)`` answers locally. Exposed
    /// here so the check is reachable from the client you already hold; the same
    /// function is also available on its own as ``InternetData/isBogon(_:)``.
    public func isBogon(_ ip: String) -> Bool {
        InternetData.isBogon(ip)
    }

    /// Look one address up: what every database says about it, as much as your
    /// plan shows.
    ///
    /// A bogon is answered locally and never reaches the network. Everything
    /// else is served, then cached for this instance. An AS or a domain is not an
    /// address: ask ``lookupASN(_:retries:timeout:)`` or
    /// ``lookupDomain(_:retries:timeout:)``, since this call refuses one as
    /// ``InternetDataErrorKind/badRequest`` before sending anything.
    ///
    /// - Parameters:
    ///   - retries: Overrides the client's retry count for this call.
    ///   - timeout: Overrides the client's ``Options/timeout`` for this call, in
    ///     either direction. It bounds each attempt, from sending the request to
    ///     decoding the answer.
    public func lookup(
        _ ip: String, retries: Int? = nil, timeout: Duration? = nil,
    ) async throws -> LookupResult {
        // Refused before a bogon or a cached answer, which need no request, or the
        // bound would be refused only when one went out.
        if let timeout {
            try checkTimeout(timeout)
        }
        if let retries {
            try checkRetries(retries)
        }
        // Judged, cached and sent as the IPv4 address it carries, if it is mapped.
        let ip = unmapped(ip)
        // The API answers an AS or a domain at the same path, in a shape this call
        // cannot read, so a string that is no address is refused here instead.
        guard isAddress(ip) else {
            throw InternetDataError(
                kind: .badRequest,
                message: "'\(ip)' is not an IP address: look up an AS with lookupASN, and a domain with lookupDomain",
            )
        }
        if isBogon(ip) {
            return LookupResult.bogon(ip)
        }
        guard let cache else {
            return try await fetch(ip, retries: retries, timeout: timeout)
        }
        // Concurrent misses for one address share one request: the first leads it
        // and the rest wait for its landing, a batch's included.
        while true {
            switch await cache.claim(ip) {
            case .hit(let hit):
                return hit
            case .lead(let flight):
                let result: LookupResult
                do {
                    result = try await fetch(ip, retries: retries, timeout: timeout)
                } catch {
                    await cache.land(ip, flight, Self.landing(for: error))
                    throw error
                }
                await cache.land(ip, flight, .served(result))
                return result
            case .wait(let ticket):
                switch await cache.collect(ticket) {
                case .served(let result):
                    return result
                case .failed(let error):
                    throw error
                case .abandoned:
                    continue
                case .cancelled:
                    throw CancellationError()
                }
            }
        }
    }

    private func fetch(_ ip: String, retries: Int?, timeout: Duration?) async throws -> LookupResult {
        try await withRetry(retries ?? self.retries) {
            try await withDeadline(timeout ?? self.timeout) {
                let output = try await api.lookupIp(path: .init(ip: ip))
                guard case .ok(let ok) = output else {
                    throw InternetDataError(
                        kind: .serverError, message: "unexpected response: \(output)",
                    )
                }
                return LookupResult(try ok.body.json)
            }
        }
    }

    // A leader cut off by its own cancellation fails nobody: each waiter asks again.
    private static func landing(for error: any Error) -> ResultCache.Landing {
        error is CancellationError || Task.isCancelled ? .abandoned : .failed(error)
    }

    /// Look up the address this client is calling from.
    ///
    /// The same answer ``lookup(_:retries:timeout:)`` would give for that address, at
    /// the same cost against your allowance. The address is the one our edge
    /// observed, so a call made through a proxy or a VPN reports the exit it
    /// left through - usually the point of asking.
    ///
    /// Deliberately NOT cached. The cache is keyed by address, and which
    /// address this is IS the question: a machine that moves between networks
    /// would otherwise be told where it used to be.
    ///
    /// - Parameters:
    ///   - retries: Overrides the client's retry count for this call.
    ///   - timeout: Bounds each attempt, as on ``lookup(_:retries:timeout:)``.
    public func myIP(retries: Int? = nil, timeout: Duration? = nil) async throws -> LookupResult {
        if let retries {
            try checkRetries(retries)
        }
        return try await withRetry(retries ?? self.retries) {
            try await withDeadline(timeout ?? self.timeout) {
                let output = try await api.lookupMyIp()
                guard case .ok(let ok) = output else {
                    throw InternetDataError(
                        kind: .serverError, message: "unexpected response: \(output)",
                    )
                }
                return LookupResult(try ok.body.json)
            }
        }
    }

    /// Look one autonomous system up: its registration on every plan, and on a
    /// paid one its ASN Whois record and the prefixes it announces.
    ///
    /// Sent as given and never cached; an AS no database knows answers its
    /// number with empty values.
    ///
    /// - Parameters:
    ///   - retries: Overrides the client's retry count for this call.
    ///   - timeout: Bounds each attempt, as on ``lookup(_:retries:timeout:)``.
    public func lookupASN(
        _ asn: UInt32, retries: Int? = nil, timeout: Duration? = nil,
    ) async throws -> AsnLookupResult {
        if let retries {
            try checkRetries(retries)
        }
        return try await withRetry(retries ?? self.retries) {
            try await withDeadline(timeout ?? self.timeout) {
                let output = try await api.lookupAsn(path: .init(asn: String(asn)))
                guard case .ok(let ok) = output else {
                    throw InternetDataError(
                        kind: .serverError, message: "unexpected response: \(output)",
                    )
                }
                return AsnLookupResult(try ok.body.json)
            }
        }
    }

    /// Look one domain up: whether it is registered and which DNS record types it
    /// has on every plan, and on a paid one the records, its organization's IP
    /// ranges and whether it is a disposable email domain.
    ///
    /// Sent as given, escaped for the path, and never cached. The API reads an
    /// internationalized name and answers under its punycode spelling, and
    /// refuses what it cannot read as a domain as a bad request.
    ///
    /// - Parameters:
    ///   - retries: Overrides the client's retry count for this call.
    ///   - timeout: Bounds each attempt, as on ``lookup(_:retries:timeout:)``.
    public func lookupDomain(
        _ domain: String, retries: Int? = nil, timeout: Duration? = nil,
    ) async throws -> DomainLookupResult {
        if let retries {
            try checkRetries(retries)
        }
        return try await withRetry(retries ?? self.retries) {
            try await withDeadline(timeout ?? self.timeout) {
                let output = try await api.lookupDomain(path: .init(domain: domain))
                guard case .ok(let ok) = output else {
                    throw InternetDataError(
                        kind: .serverError, message: "unexpected response: \(output)",
                    )
                }
                return DomainLookupResult(try ok.body.json)
            }
        }
    }

    /// What this client's key is entitled to, and how much of it has been used.
    ///
    /// Named for what it answers rather than `me`, which sits one letter from
    /// ``myIP(retries:timeout:)`` and means something quite different: one is which
    /// address you are calling FROM, the other is what the key you are calling
    /// WITH may spend.
    ///
    /// Unlike a lookup there is no useful unauthenticated answer, so a client
    /// built without an API key gets an unauthorized error rather than a
    /// partial one.
    ///
    /// Usage counts against the ALLOWANCE WINDOW - on a paid plan the
    /// anniversary of the subscription, not the calendar month and not the
    /// billing period, and on the free plan the UTC day - and it is the same
    /// number a lookup is gated on. It can lag by a few seconds, because
    /// requests are counted in memory and flushed in aggregate.
    ///
    /// Deliberately NOT cached: the whole point is what has been spent, and a
    /// cached answer is a wrong one within seconds of the next request.
    ///
    /// - Parameters:
    ///   - retries: Overrides the client's retry count for this call.
    ///   - timeout: Bounds each attempt, as on ``lookup(_:retries:timeout:)``.
    public func myEntitlement(
        retries: Int? = nil, timeout: Duration? = nil,
    ) async throws -> Entitlement {
        if let retries {
            try checkRetries(retries)
        }
        return try await withRetry(retries ?? self.retries) {
            try await withDeadline(timeout ?? self.timeout) {
                let output = try await api.myEntitlement()
                guard case .ok(let ok) = output else {
                    throw InternetDataError(
                        kind: .serverError, message: "unexpected response: \(output)",
                    )
                }
                return Entitlement(try ok.body.json)
            }
        }
    }

    /// Looks many addresses up in as few requests as possible.
    ///
    /// Bogons are answered locally and cached answers are reused; everything
    /// else goes to `POST /batch` in chunks of up to 1000 addresses, with at
    /// most `concurrency` chunks in flight. Keyed by address rather than
    /// positional, so duplicates in the input collapse to a single entry and the
    /// caller never has to line two lists up. An address that fails carries its
    /// error as its value, so one bad entry cannot lose the rest of the answers:
    /// the API reports a per-entry failure with the status the single lookup
    /// would have answered, and a chunk that fails as a whole marks every
    /// address in it. The batch endpoint needs a paid plan: without a key every
    /// address in a request of two or more carries an unauthorized error, and a
    /// free-plan key's request of two or more a bad request (HTTP 402). A
    /// request of one address is answered as its lookup would be.
    ///
    /// Throws only when cancelled, or when ``BatchOptions/concurrency`` is below
    /// 1 or ``BatchOptions/timeout`` is a bound no attempt could meet, each
    /// refused as ``InternetDataErrorKind/badRequest`` before any request.
    public func lookupBatch(
        _ ips: some Sequence<String>, options: BatchOptions = BatchOptions(),
    ) async throws -> BatchResults {
        let limit = options.concurrency ?? concurrency
        // A group primed with no children would wait for none, forever.
        guard limit > 0 else {
            throw InternetDataError(
                kind: .badRequest, message: "concurrency must be at least 1, got \(limit)",
            )
        }
        // Refused up front, like the concurrency above: a batch answers bogons and
        // cache hits without an attempt, so a bound checked only per chunk would be
        // accepted or refused depending on which addresses it happened to hold.
        if let timeout = options.timeout {
            try checkTimeout(timeout)
        }
        if let retries = options.retries {
            try checkRetries(retries)
        }

        // An IPv4-mapped address is sent as the address it carries, once however
        // many of its spellings were asked, and answered under each one asked.
        var asked: [String] = []
        var seenAsked: Set<String> = []
        var keys: [String] = []
        var seen: Set<String> = []
        for ip in ips where seenAsked.insert(ip).inserted {
            asked.append(ip)
            let carried = unmapped(ip)
            if seen.insert(carried).inserted {
                keys.append(carried)
            }
        }

        var outcomes: [String: BatchResults.Outcome] = [:]
        outcomes.reserveCapacity(keys.count)
        var served: [String] = []
        for ip in keys {
            if isBogon(ip) {
                outcomes[ip] = .success(LookupResult.bogon(ip))
                continue
            }
            served.append(ip)
        }
        // Boarded in one step, before any chunk is built: an address already in
        // flight is waited for rather than sent, and a lookup arriving meanwhile
        // waits for this batch's answer.
        var pending: [String] = []
        var led: [String: UUID] = [:]
        var waiting: [(String, UUID)] = []
        if let cache {
            let claims = await cache.board(served)
            for ip in served {
                switch claims[ip] {
                case .hit(let hit):
                    outcomes[ip] = .success(hit)
                case .lead(let flight):
                    led[ip] = flight
                    pending.append(ip)
                case .wait(let ticket):
                    waiting.append((ip, ticket))
                case nil:
                    pending.append(ip)
                }
            }
        } else {
            pending = served
        }
        let chunks = stride(from: 0, to: pending.count, by: Self.batchMax).map {
            Array(pending[$0..<min($0 + Self.batchMax, pending.count)])
        }

        // Primed with `limit` children and topped back up as each one lands, so
        // peak in-flight is the limit rather than the number of chunks, and a
        // per-call limit has no shared limiter that could cap it.
        do {
            try await withThrowingTaskGroup(of: [(String, BatchResults.Outcome)].self) { group in
                var next = 0
                while next < min(limit, chunks.count) {
                    guard group.addTaskUnlessCancelled(operation: chunkTask(chunks[next], led, options)) else {
                        break
                    }
                    next += 1
                }
                while let answers = try await group.next() {
                    for (ip, outcome) in answers {
                        outcomes[ip] = outcome
                    }
                    guard next < chunks.count else {
                        continue
                    }
                    group.addTask(operation: chunkTask(chunks[next], led, options))
                    next += 1
                }
            }
        } catch {
            await abandon(led)
            throw error
        }
        // A chunk never started, its batch cancelled first, landed nothing.
        await abandon(led)
        // Covers the one case no child can report: cancellation before the group
        // was primed, where nothing ran and the result would otherwise be keys
        // with no outcome behind them.
        try Task.checkCancellation()
        for (ip, ticket) in waiting {
            outcomes[ip] = try await collect(ip, ticket, options)
        }
        var byAsked: [String: BatchResults.Outcome] = [:]
        byAsked.reserveCapacity(asked.count)
        for ip in asked {
            byAsked[ip] = outcomes[unmapped(ip)]
        }
        return BatchResults(keys: asked, outcomes: byAsked)
    }

    /// One chunk, sent, with each answer landed for whoever waits on its address.
    private func chunkTask(
        _ chunk: [String], _ led: [String: UUID], _ options: BatchOptions,
    ) -> @Sendable () async throws -> [(String, BatchResults.Outcome)] {
        { [self] in
            let answers = try await sendChunk(chunk, options)
            for (ip, outcome) in answers {
                guard let cache, let flight = led[ip] else {
                    continue
                }
                switch outcome {
                case .success(let result):
                    await cache.land(ip, flight, .served(result))
                case .failure(let error):
                    await cache.land(ip, flight, .failed(error))
                }
            }
            return answers
        }
    }

    /// One `POST /batch`, mapped back onto the addresses it was asked about. A
    /// chunk-level failure - the call refused, the transport failing, the
    /// retries exhausted - becomes every address's error, exactly as it would
    /// have been had each been looked up alone.
    private func sendChunk(
        _ chunk: [String], _ options: BatchOptions,
    ) async throws -> [(String, BatchResults.Outcome)] {
        let answers: [String: BatchResults.Outcome]
        do {
            answers = try await withRetry(options.retries ?? retries) {
                try await withDeadline(options.timeout ?? timeout) {
                    try await postBatch(chunk)
                }
            }
        } catch is CancellationError {
            // The batch is being torn down; that is not this chunk failing.
            throw CancellationError()
        } catch {
            let failure = InternetDataError.wrapping(error)
            return chunk.map { ($0, .failure(failure)) }
        }
        return chunk.map { ip in
            (ip, answers[ip] ?? .failure(InternetDataError(
                kind: .serverError, message: "the batch answer did not include \(ip)", status: 200,
            )))
        }
    }

    /// One `POST /batch` through the client's middlewares, its answer read entry
    /// by entry, so one entry it cannot read is that address's error alone and
    /// only an answer holding neither map, or none at all, fails the chunk.
    private func postBatch(_ chunk: [String]) async throws -> [String: BatchResults.Outcome] {
        var fields = HTTPFields()
        fields[.accept] = "application/json"
        fields[.contentType] = "application/json"
        let request = HTTPRequest(method: .post, scheme: nil, authority: nil, path: "/batch", headerFields: fields)
        let payload = try JSONEncoder().encode(Components.Schemas.BatchLookupRequest(ips: chunk))
        let (response, responseBody) = try await send(request, HTTPBody(payload), operationID: "lookupBatch")
        let status = Int(response.status.code)
        guard let bytes = try? await ArraySlice(collecting: responseBody ?? HTTPBody(), upTo: .max),
            let envelope = try? answerDecoder().decode(BatchEnvelope.self, from: Data(bytes)),
            envelope.results != nil || envelope.errors != nil
        else {
            throw InternetDataError.unreadable("the response", status: status)
        }
        var answers: [String: BatchResults.Outcome] = [:]
        for ip in chunk {
            if let entry = envelope.results?[ip] {
                guard let served = entry.value else {
                    answers[ip] = .failure(.unreadable("the entry for \(ip)", status: status))
                    continue
                }
                answers[ip] = .success(LookupResult(served))
            } else if let entry = envelope.errors?[ip] {
                guard let failed = entry.value else {
                    answers[ip] = .failure(.unreadable("the error for \(ip)", status: status))
                    continue
                }
                answers[ip] = .failure(InternetDataError.fromEntry(status: failed.status, message: failed.error))
            }
        }
        return answers
    }

    /// A request through the same middlewares, in the same order, as the
    /// generated client runs them.
    private func send(
        _ request: HTTPRequest, _ body: HTTPBody?, operationID: String,
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?) = {
            [transport] request, body, baseURL in
            try await transport.send(request, body: body, baseURL: baseURL, operationID: operationID)
        }
        for middleware in middlewares.reversed() {
            let inner = next
            next = { request, body, baseURL in
                try await middleware.intercept(
                    request, body: body, baseURL: baseURL, operationID: operationID, next: inner,
                )
            }
        }
        return try await next(request, body, baseURL)
    }

    // Every flight this batch led and has not landed, so no waiter waits on it.
    private func abandon(_ led: [String: UUID]) async {
        guard let cache else {
            return
        }
        for (ip, flight) in led {
            await cache.land(ip, flight, .abandoned)
        }
    }

    // An address another call had in flight when this batch boarded: its answer,
    // or, its leader cancelled, this batch's own lookup of it.
    private func collect(
        _ ip: String, _ ticket: UUID, _ options: BatchOptions,
    ) async throws -> BatchResults.Outcome {
        guard let cache else {
            throw CancellationError()
        }
        switch await cache.collect(ticket) {
        case .served(let result):
            return .success(result)
        case .failed(let error):
            return .failure(InternetDataError.wrapping(error))
        case .cancelled:
            throw CancellationError()
        case .abandoned:
            do {
                return .success(try await lookup(ip, retries: options.retries, timeout: options.timeout))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return .failure(InternetDataError.wrapping(error))
            }
        }
    }
}

extension InternetDataClient {
    /// How a client behaves. Everything has a default; an empty `Options` is no
    /// API key against production.
    public struct Options: Sendable {
        /// Your API key. Without one a lookup is on Unlimited, the free plan,
        /// limited per address per minute. Every paid plan answers every field,
        /// and a batch needs one. A database call needs a key carrying the
        /// `db.download` scope; ``InternetDataClient/oauth`` takes none.
        public var apiKey: String?
        /// Where the API is served. Default ``InternetDataClient/defaultBaseURL``.
        ///
        /// A trailing slash is dropped. Every path this client appends begins with
        /// one and the transport appends it to whatever path the base URL already
        /// carries, so `https://api.internetdata.io/` would ask for `//api/v2/...`.
        /// That is a different path to the server, which answers it with a
        /// redirect the default transport refuses to follow, so every call would fail.
        ///
        /// ``InternetDataClient/oauth`` signs in at the apex rather than here, which
        /// serves no OAuth path: a leading `api.` is dropped and `api-<name>.`
        /// becomes `<name>.`, so the default signs in at `https://internetdata.io`.
        /// Any other base URL is used as given.
        public var baseURL: URL
        /// Set to `nil` to disable caching.
        public var cache: CacheOptions?
        /// Concurrent batch requests - chunks of up to 1000 addresses - during a batch. Default 8.
        public var concurrency: Int
        /// Retry attempts for a transient failure. Default 2.
        public var retries: Int
        /// How long one attempt may take, from sending the request to decoding
        /// the answer. Default 30 seconds. Per ATTEMPT, so a retried call may
        /// take longer in total, and a call's own `timeout` replaces it in either
        /// direction. A database transfer is bounded only until its response head
        /// arrives, so a download that takes minutes is not cut off.
        ///
        /// Must be positive, and short enough for the concurrency runtime to count
        /// to. Zero, a negative duration and one near the top of `Int64` seconds
        /// are each a bound no attempt could meet; a call given one refuses it as
        /// ``InternetDataErrorKind/badRequest`` rather than failing on the wire.
        public var timeout: Duration
        /// Override the HTTP implementation. Anything you supply owns its own
        /// redirect policy, and the download endpoint's `302` must not be
        /// followed; see ``DatabaseAPI/downloadURL(id:format:timeout:)``.
        public var transport: (any ClientTransport)?

        public init(
            apiKey: String? = nil,
            baseURL: URL = InternetDataClient.defaultBaseURL,
            cache: CacheOptions? = CacheOptions(),
            concurrency: Int = 8,
            retries: Int = 2,
            timeout: Duration = .seconds(30),
            transport: (any ClientTransport)? = nil,
        ) {
            self.apiKey = apiKey
            self.baseURL = baseURL
            self.cache = cache
            self.concurrency = concurrency
            self.retries = retries
            self.timeout = timeout
            self.transport = transport
        }

        /// The initializer before the cache and the batch concurrency arrived,
        /// kept so a reference to it still compiles; it takes their defaults.
        public init(
            apiKey: String? = nil,
            baseURL: URL = InternetDataClient.defaultBaseURL,
            retries: Int = 2,
            timeout: Duration = .seconds(30),
            transport: (any ClientTransport)? = nil,
        ) {
            self.init(
                apiKey: apiKey, baseURL: baseURL, cache: CacheOptions(), concurrency: 8, retries: retries,
                timeout: timeout, transport: transport,
            )
        }
    }

    /// Per-call overrides for one batch. Anything left `nil` falls back to the
    /// client's setting.
    ///
    /// There is deliberately no equivalent on ``lookup(_:retries:timeout:)``: a
    /// concurrency for a single address is meaningless, and a type that accepted
    /// one and ignored it would pass any test that only checked the option was
    /// accepted.
    public struct BatchOptions: Sendable, Hashable {
        /// Concurrent batch requests - chunks of up to 1000 addresses - for THIS batch only.
        public var concurrency: Int?
        /// Retry attempts for a transient failure, for THIS batch only.
        public var retries: Int?
        /// How long one attempt at one chunk may take, for THIS batch only, in
        /// place of the client's ``InternetDataClient/Options/timeout``. A chunk
        /// that runs out of it marks every address in it with a retryable network
        /// error. One no attempt could meet is refused as
        /// ``InternetDataErrorKind/badRequest`` before any request, as a
        /// ``concurrency`` below 1 is.
        public var timeout: Duration?

        public init(concurrency: Int? = nil, retries: Int? = nil, timeout: Duration? = nil) {
            self.concurrency = concurrency
            self.retries = retries
            self.timeout = timeout
        }
    }
}

// Every path the generated client appends begins with a slash, and the transport
// appends it to whatever path the base URL already carries, so a base URL ending
// in one asks for `//api/v2/...`. That is a different path to the server, which
// answers it with a redirect the default transport refuses to follow, so every
// call fails. Every trailing slash goes rather than one: dropping a single slash
// still doubles `.../`.
private func withoutTrailingSlashes(_ url: URL) -> URL {
    var text = url.absoluteString
    while text.hasSuffix("/") {
        text.removeLast()
    }
    return URL(string: text) ?? url
}

// The authorization server is the apex, not the API host, which serves no OAuth
// path: a leading `api.` goes, `api-<name>.` becomes `<name>.`, and any other
// host is used as given.
private func authorizationServer(of baseURL: URL) -> URL {
    guard var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false), let host = parts.host,
        let dot = host.firstIndex(of: "."), host.index(after: dot) < host.endIndex
    else {
        return baseURL
    }
    let label = host[..<dot].lowercased()
    let rest = host[host.index(after: dot)...]
    if label == "api" {
        parts.host = String(rest)
    } else if label.hasPrefix("api-"), label.count > 4 {
        parts.host = "\(host[host.index(host.startIndex, offsetBy: 4)..<dot]).\(rest)"
    } else {
        return baseURL
    }
    return parts.url ?? baseURL
}

/// A batch's answer with each entry kept apart, so one the client cannot read
/// fails only its own address.
private struct BatchEnvelope: Decodable {
    var results: [String: Entry<Components.Schemas.LookupResponse>]?
    var errors: [String: Entry<Components.Schemas.BatchLookupError>]?

    /// One entry, or nil where it could not be read.
    struct Entry<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: any Decoder) throws {
            value = try? Value(from: decoder)
        }
    }
}

/// Reads an answer as the generated client does, its dates through the same
/// transcoder.
private func answerDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    let transcoder = RFC3339DateTranscoder()
    decoder.dateDecodingStrategy = .custom { decoder in
        try transcoder.decode(decoder.singleValueContainer().decode(String.self))
    }
    return decoder
}
