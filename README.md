# [<img src="https://s3.internetdata.io/internetdata-public/brand/mark.svg" alt="InternetData" height="28"/>](https://internetdata.io/) InternetData Swift Client Library

[![Swift](https://img.shields.io/badge/swift-6.1%2B-F05138.svg)](https://swift.org)
[![license](https://img.shields.io/github/license/internetdata/sdk-swift)](LICENSE)

The official Swift client library for the [InternetData](https://internetdata.io) API.

It tells you what every InternetData database says about an IP address, an AS or a domain, and it downloads the databases your organization is licensed for.

## Getting Started

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/internetdata/sdk-swift.git", from: "2.10.1"),
]
```

and the library to your target. The repository ends in `sdk-swift`, which is the package name SwiftPM derives, but the library it exposes is `InternetData`:

```swift
.target(
    name: "YourTarget",
    dependencies: [.product(name: "InternetData", package: "sdk-swift")],
)
```

Requires Swift 6.1 or newer, and macOS 13, iOS 16, tvOS 16, watchOS 9 or visionOS 1 on Apple platforms. Linux is supported on any distribution the Swift toolchain runs on.

## Usage

**No API key needed to start.** Unlimited, the free plan, answers the address's country, its AS, who uses it, its reverse DNS name and abuse contact, and the Tor, relay, anycast, carrier, satellite and services flags, limited per address per minute.

```swift
import InternetData

let client = InternetDataClient()

let result = try await client.lookup("146.70.116.130")
print(result.location.country)   // AT
print(result.asn.name)           // M247 Europe SRL
print(result.isTor)              // false
```

### With an API key

Every paid plan answers every field: the VPN, proxy, hosting and CDN flags and the provider and confidence behind each, the city and the coordinates, the Whois records and the hosted domain count. The plans differ only in how many lookups they include, and a free account tries every field, 100 lookups a day. Create a key in the [console](https://app.internetdata.io), then pass it in:

```swift
let client = InternetDataClient(apiKey: ProcessInfo.processInfo.environment["INTERNETDATA_API_KEY"]!)

let result = try await client.lookup("146.70.116.130")
print(result.isVpn)               // Optional(true), on a paid plan
print(result.vpn?.providerName)   // Optional("Mullvad"), on a paid plan
print(result.location.city)       // Optional("Vienna"), on a paid plan
```

Every setting has a default, and `InternetDataClient.Options` is where you change one:

```swift
let client = InternetDataClient(options: .init(apiKey: key, concurrency: 32, retries: 4))
```

### Your own address

```swift
let result = try await client.myIP()
print(result.ip)   // the address we saw this call come from
```

Same answer `lookup` would give for that address, and the same cost against your allowance. It is deliberately not cached: which address you are is the whole question, and a machine that moves between networks would otherwise be told where it used to be.

### An AS or a domain

```swift
let asn = try await client.lookupASN(9009)
print(asn.name, asn.registry)    // M247 Europe SRL ripe

let domain = try await client.lookupDomain("example.com")
print(domain.isRegistered)       // true
print(domain.dns?.mx.first?.host) // on a paid plan
```

A paid plan adds an AS's Whois record and the prefixes it announces, and a domain's DNS records, its organization's IP ranges and whether it's a disposable email domain. Neither is cached or batched, and `lookup` takes an address alone: it refuses an AS or a domain as `badRequest` before sending anything.

### Your plan and usage

```swift
let acct = try await client.myEntitlement()
print(acct.plan.key)          // max
print(acct.usage.requests)    // 580
print(acct.usage.windowEnd)   // when the allowance resets
```

Usage counts against the anniversary of your subscription on a paid plan, not the calendar month and not the billing period, and against the UTC day on the free plan; it is the same number a lookup is gated on. `hardLimit` is `nil` on an uncapped plan, which is not the same as zero.

### Batch lookup

Look up many addresses at once. Bogons and cached answers are handled locally, and everything else goes to the batch endpoint in chunks of up to 1000 addresses, in parallel. The batch endpoint needs a paid plan:

```swift
let results = try await client.lookupBatch(["146.70.116.130", "8.8.8.8", "1.1.1.1"])

for (ip, outcome) in results {
    switch outcome {
    case .success(let result):
        print("\(ip): \(result.asn.name)")
    case .failure(let error):
        print("\(ip): \(error)")
    }
}
```

Results are keyed by address, in the order you first listed each one, so duplicates in your list collapse into a single entry and one address failing never loses the rest: it carries its error as its value, with the status the API would have given that address on its own. `results["8.8.8.8"]` gets one back on its own, and `results.keys` is the order you passed in.

How many chunks are in flight at once, how many times a failed chunk is retried, and how long each attempt at a chunk may take, are configurable per call:

```swift
let results = try await client.lookupBatch(manyIps, options: .init(concurrency: 4, retries: 4, timeout: .seconds(10)))
```

### Caching

Answers are cached by default, so repeat lookups of the same address are free:

```swift
let client = InternetDataClient()

let result = try await client.lookup("146.70.116.130")
print(result.asn.name)    // M247 Europe SRL, API request

let result2 = try await client.lookup("146.70.116.130")
print(result2.asn.name)   // M247 Europe SRL, no API request, result was cached
```

You can change the default cache variables (max size, TTL, etc) on initialization, or even disable it:

```swift
let client = InternetDataClient(options: .init(cache: .init(maxEntries: 50_000, ttl: .seconds(6 * 3600))))
let clientNoCache = InternetDataClient(options: .init(cache: nil))
```

### Private and reserved addresses

Private, loopback, link-local, documentation and multicast addresses (and their IPv6 equivalents, including the 6to4 and Teredo ranges) are reserved space no database says anything about. The library answers them locally, so they cost no request and no quota:

```swift
let result = try await client.lookup("192.168.1.1")
result.isBogon   // true
result.isVpn     // Optional(false)
```

The check is available on the client, which is handy when your inputs are addresses anyway:

```swift
client.isBogon("10.0.0.1")   // true
client.isBogon("8.8.8.8")    // false
```

It is also a free function, if you want it without a client:

```swift
import InternetData

isBogon("10.0.0.1")   // true
```

### Errors

Failures throw an `InternetDataError` carrying a `kind`, the API's own message, and an `isRetryable` flag:

```swift
do {
    _ = try await client.lookup("146.70.116.130")
} catch let error as InternetDataError {
    print(error.kind, error.message, error.isRetryable)
}
```

`kind` is one of `badRequest`, `unauthorized`, `forbidden`, `rateLimited`, `quotaExceeded`, `serverError` or `network`. A database call's `message` is the API's `rc`, such as `NOT_LICENSED`.

Note that `rateLimited` and `quotaExceeded` both arrive as HTTP 429 and are not the same thing. A rate limit carries `Retry-After`, so retrying later works; but a spent quota needs your allowance raised or the window to roll over. The library retries rate limits for you, waiting as long as the API asks, but not if your quota is exceeded.

Each attempt is abandoned after 30 seconds by default (`timeout` on the options), which fails as a retryable `network` error. A download is timed only until object storage starts answering, so a large file is never cut off. One call can set its own, longer or shorter - `lookup`, `myIP`, `lookupASN`, `lookupDomain`, `myEntitlement`, a batch, every `oauth` method, and every `client.database` call but the transfers:

```swift
let result = try await client.lookup("146.70.116.130", timeout: .seconds(5))
let databases = try await client.database.list(timeout: .seconds(5))
```

`lookup`, `myIP`, `lookupASN`, `lookupDomain`, `myEntitlement` and a batch take `retries` for that call alone the same way, and one below zero is refused as `badRequest` before any request.

### Database downloads

Every database published today needs an API key carrying the `db.download` scope. The Open databases are licensed to every organization from the start and are free under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/), and `list()` marks them `open`. The rest are licensed by contract, one family at a time: if your organization doesn't have a license yet, [request an evaluation](https://internetdata.io/contact?purpose=evaluation&subject=Evaluation+license).

```swift
let client = InternetDataClient(apiKey: ProcessInfo.processInfo.environment["INTERNETDATA_API_KEY"]!)

for database in try await client.database.list() {
    print(database.base, database.standing, database.versions.map(\.id))
    // vpn_ip  licensed  ["vpn_ip_v1"]
}
```

The database calls live under `client.database`, where the sibling VPNDetection client spells the same seven the same way, so a codebase holding both does not have to remember which one is flat.

A license is held against a FAMILY (`vpn_ip`), while a download names a VERSION (`vpn_ip_v1`), so the IDs everything below takes come from `versions`. Old versions are frozen rather than migrated, so both stay downloadable.

`list`, `metadata`, `checksums`, `downloads` and `downloadURL` each take a `timeout` of their own. The transfers deliberately take none, so there is nothing to pass and a call that tries does not compile rather than accepting the option and quietly doing nothing with it: a database runs to gigabytes and minutes, so any bound that suits a JSON call would abandon a healthy download. `downloadURL` does take one, because minting the link is an ordinary API request - it bounds that request, not whatever you do with the link afterwards.

### What is inside a database

`metadata` carries the build date, the row count, the columns and the size of every format, without downloading anything. Poll it to decide whether today's build is worth fetching, and read `size` to budget the transfer:

```swift
let metadata = try await client.database.metadata(id: "vpn_ip_v1")

print(metadata.updated)              // "2026-09-04"
print(metadata.entries)              // 3_214_887
print(metadata.size["mmdb"])         // Optional(48_213_504)
print(metadata.schema["csvgz"]?.map(\.name) ?? [])
print(metadata.sample["csvgz"]?.first ?? [:])
```

Not every database is built in every format: the `_provider` catalogs are keyed by provider ID rather than by IP range, so asking them for an MMDB is a `badRequest` rather than a gap. `DatabaseVersion.formats` says which exist.

### Downloading

`download` streams straight to disk, so nothing bigger than a single chunk is ever held in memory whatever the file weighs. It writes a neighbouring `.part` file and renames it on success, so a transfer that dies half way leaves nothing that reads as a whole database:

```swift
let written = try await client.database.download(
    "vpn_ip_v1", format: .mmdb,
    to: URL(fileURLWithPath: "vpn_ip_v1.mmdb"),
)
print("\(written) bytes")
```

Hand it a closure instead when the bytes are going somewhere other than a file: a parser, an archive, another socket. The closure is awaited, so a slow sink slows the transfer rather than queueing behind it:

```swift
try await client.database.download("vpn_ip_v1", format: .csvgz) { chunk in
    try await gunzip.write(chunk)
}
```

`downloadBytes` hands the whole file back at once. It holds all of it in memory, and the catalog spans seven orders of magnitude, so reach for it at the small end and use `download` for anything you have not measured:

```swift
let bytes = try await client.database.downloadBytes("bogon_asn_v1", format: .csvgz)
```

### Download links you can hand out

The API answers a download with a `302` to a time-limited link that carries its own signature, so `downloadURL` gives you something you can pass to a job runner, a CDN or a shell script that holds no API key at all:

```swift
let url = try await client.database.downloadURL(id: "vpn_ip_v1", format: .mmdb)
```

The link authorizes the START of a transfer, so one already running is not interrupted when it lapses.

### Downloading a named build

Each download call fetches the build that is live unless you name one. A `database.updated` webhook names the build it announces and carries its `sha256`, so a receiver that downloads after the next publish asks for that build to get the file the hash is of:

```swift
try await client.database.download("vpn_ip_v1", format: .mmdb, build: build, to: destination)
```

`downloadURL` and `downloadBytes` take `build:` the same way. A build is kept 7 days. Past that the call throws `badRequest` with the message `BUILD_GONE`, and downloading without a build fetches the live one.

### Verifying a download

`checksums` returns the whole published digest set for one file rather than a single algorithm:

```swift
let checksums = try await client.database.checksums(id: "vpn_ip_v1", format: .mmdb)
print(checksums.sha256)
```

### Recent download attempts

`downloads` lists what your organization has fetched, newest first. Refusals are listed too, because a denial is what answers "it stopped working" and its absence answers nothing:

```swift
for attempt in try await client.database.downloads(limit: 20) {
    print(attempt.created, attempt.datasetId, attempt.outcome, attempt.bytes ?? 0)
}
```

### What `list` shows you

Nothing here is cached, deliberately, and you should not cache it either: a listing belongs to the key that fetched it, and reusing one across keys will show an organization a catalog that is not its own.

### Sign in with OAuth (device flow)

A program running on the person's own machine can let them sign in with a browser and pick one of their API keys, instead of asking them to paste it:

```swift
let client = InternetDataClient()

let device = try await client.oauth.deviceAuthorization(
    clientID: "your-client-id", scope: "account.read apikeys.read apikeys.reveal",
)
print("Open \(device.verificationURI) and enter \(device.userCode)")

let token = try await client.oauth.pollDeviceToken(device, clientID: "your-client-id")
guard let apikey = token.apikey else {
    fatalError("no API key came back: none was picked, or it can't be shown again")
}
let keyed = InternetDataClient(apiKey: apikey)
```

A denied sign-in throws `OauthError.accessDenied` and a code that ran out `OauthError.expiredToken`. Client IDs are issued on request from support@internetdata.io, and `client.oauth.revoke(refreshToken, clientID: "your-client-id")` signs the machine out again.

### Sign in with OAuth (authorization code)

An app that can take a browser redirect signs the person in there instead, with a PKCE pair made for that one sign-in:

```swift
let client = InternetDataClient()
let redirectURI = "http://127.0.0.1:8765/callback"
let pkce = client.oauth.createPkce()

let url = try client.oauth.authorizationURL(
    clientID: "your-client-id", redirectURI: redirectURI, codeChallenge: pkce.challenge,
    scope: "apikeys.use", state: "your-state",
)
// Open url in the browser. Its redirect to redirectURI carries code and state.
let token = try await client.oauth.exchangeAuthorizationCode(
    code, clientID: "your-client-id", codeVerifier: pkce.verifier, redirectURI: redirectURI,
)
```

Check that `state` came back as you sent it before you exchange `code`, which works once. The client ID can also be the https URL of a client metadata document your app serves, and such an app is never handed a key, so `token.apikey` stays `nil`.

### Register a client

An app with no client ID, and no client metadata document to use as one, registers itself, then signs in with the `clientID` it gets back as the client ID for `authorizationURL` and `exchangeAuthorizationCode`:

```swift
let client = InternetDataClient()
let registration = try await client.oauth.register(
    redirectURIs: ["http://127.0.0.1:8765/callback"], clientName: "Your App")
```

Each redirect URI must be https on a public host name, or http on a loopback address, which then matches any port. Nothing is kept until a person approves the client, so an app with no client ID saved can simply register again.

### Absent is not false

Unlimited leaves out `isVpn`, the proxy, hosting and CDN flags and the detail behind them, the Whois records and the paid members inside `location`, `asn`, `company` and `abuse`, such as `location.city`; a free-plan key's answer carries `trialExpired`, true once its daily trial is spent. Every member a plan can leave out is `Optional`, where `nil` means "not in your plan" rather than "checked, and no".

```swift
result.isHosting ?? false   // when you only want the flag
result.isHosting == nil     // on Unlimited: not in your plan
result.location.city == nil // the same, inside a shared object
result.trialExpired == true // a free-plan key's daily trial is spent
```

### Supplying your own transport

By default the library talks to the API over [AsyncHTTPClient](https://github.com/swift-server/async-http-client), configured to refuse redirects. Anything conforming to `ClientTransport` can take its place. To use `URLSession` on an Apple platform, add [swift-openapi-urlsession](https://github.com/apple/swift-openapi-urlsession) to your own package and hand its transport in:

```swift
import OpenAPIURLSession

let client = InternetDataClient(options: .init(apiKey: key, transport: URLSessionTransport()))
```

One thing to know if you do: the download endpoint answers `302`, and the library follows that redirect itself as a second request rather than letting the transport do it. That is what keeps your API key off object storage, and it is what stops a whole database being read into memory before the library ever sees the link. Configure yours not to follow redirects. The library refuses such a response rather than reading it, but the transfer has already started by then.

## Other Libraries

There are official InternetData client libraries available for many languages including PHP, Python, Go, Java, and Ruby. See our GitHub at https://github.com/internetdata for more.

## About InternetData

Geolocation, anonymity, ownership and network databases for IP addresses and AS numbers, licensed as files you download and query yourself.

[<img src="https://s3.internetdata.io/internetdata-public/brand/mark.svg" alt="InternetData" height="64"/>](https://internetdata.io/)

## License

This project is licensed under the [MIT License](LICENSE).
