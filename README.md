# [<img src="https://s3.internetdata.io/internetdata-public/brand/mark.svg" alt="InternetData" width="24"/>](https://internetdata.io/) InternetData Swift Client Library

[![Swift](https://img.shields.io/badge/swift-6.1%2B-F05138.svg)](https://swift.org)
[![license](https://img.shields.io/github/license/internetdata/sdk-swift)](LICENSE)

The official Swift client library for the [InternetData](https://internetdata.io) database API.

It downloads the IP and ASN databases your organization is licensed for, verifies them against the published checksums, and tells you what is inside one before you fetch it.

## Getting Started

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/internetdata/sdk-swift.git", from: "1.0.0"),
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

Every call needs an API key carrying the `db.download` scope. Access is granted by contract, one database family at a time, so there is no self-serve signup: [talk to us](https://internetdata.io) and we will issue one.

```swift
import InternetData

let client = InternetDataClient(apiKey: ProcessInfo.processInfo.environment["INTERNETDATA_API_KEY"]!)

for database in try await client.database.list() {
    print(database.base, database.standing, database.versions.map(\.id))
    // vpn_ip  licensed  ["vpn_ip_v1"]
}
```

Every call lives under `client.database`. The downloads are the whole of this API today, but the sibling VPNDetection client spells the same seven calls the same way, so a codebase holding both does not have to remember which one is flat.

A licence is held against a FAMILY (`vpn_ip`), while a download names a VERSION (`vpn_ip_v1`), so the ids everything below takes come from `versions`. Old versions are frozen rather than migrated, so both stay downloadable.

Every setting has a default, and `InternetDataClient.Options` is where you change one:

```swift
let client = InternetDataClient(options: .init(apiKey: key, retries: 4))
```

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

Not every database is built in every format: the `_provider` catalogs are keyed by provider id rather than by IP range, so asking them for an MMDB is a `badRequest` rather than a gap. `DatabaseVersion.formats` says which exist.

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

### Errors

Failures throw an `InternetDataError` carrying a `kind`, the API's own `rc` as its `message`, and an `isRetryable` flag:

```swift
do {
    _ = try await client.database.metadata(id: "vpn_ip_v1")
} catch let error as InternetDataError {
    print(error.kind, error.message, error.isRetryable)
}
```

`kind` is one of `badRequest`, `unauthorized`, `forbidden`, `rateLimited`, `quotaExceeded`, `serverError` or `network`.

Note that `rateLimited` and `quotaExceeded` both arrive as HTTP 429 and are not the same thing. A rate limit is the API protecting itself against a burst, so retrying later works; a spent quota needs your allowance raised or the window to roll over. The library retries rate limits for you, waiting as long as the API asked, but never retries a spent quota.

### What `list` shows you

The catalog is not the same for everyone. A database built for a single customer is absent from everybody else's listing rather than shown as `unlicensed`, so `list` is the whole of what your key may see, and `standing` tells you where you stand on each entry you can see.

Nothing here is cached, deliberately, and you should not cache it either: a listing belongs to the key that fetched it, and reusing one across keys will show an organization a catalog that is not its own.

### Supplying your own transport

By default the library talks to the API over [AsyncHTTPClient](https://github.com/swift-server/async-http-client), configured to refuse redirects. Anything conforming to `ClientTransport` can take its place. To use `URLSession` on an Apple platform, add [swift-openapi-urlsession](https://github.com/apple/swift-openapi-urlsession) to your own package and hand its transport in:

```swift
import OpenAPIURLSession

let client = InternetDataClient(options: .init(apiKey: key, transport: URLSessionTransport()))
```

One thing to know if you do: the download endpoint answers `302`, and the library follows that redirect itself as a second request rather than letting the transport do it. That is what keeps your API key off object storage, and it is what stops a whole database being read into memory before the library ever sees the link. Configure yours not to follow redirects. The library refuses such a response rather than reading it, but the transfer has already started by then.

## Other Libraries

There are official InternetData client libraries available for many languages including PHP, Python, Go, Java, Ruby, and many popular frameworks such as Django, Rails, and Laravel. See our GitHub at https://github.com/internetdata for more.

## About InternetData

IP, ASN and Domain data to reveal unique insights about the internet. APIs, Databases and Live Feeds available.

[<img src="https://s3.internetdata.io/internetdata-public/brand/mark.svg" alt="InternetData" width="96"/>](https://internetdata.io/)

## License

This project is licensed under the [MIT License](LICENSE).
