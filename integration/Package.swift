// swift-tools-version: 6.1

import Foundation
import PackageDescription

// A separate package on purpose. The suite in ../Tests exercises this working
// tree; this one exercises the artifact a stranger resolves, which is the only
// way to notice a tag that never landed, a product a consumer cannot name, or a
// build plugin that refuses to run for anyone but us.
//
// SwiftPM resolves a version from a git TAG, so before the first tag there is
// nothing published to test and `scripts/run.sh` skips with a reason.
//
// INTERNETDATA_SDK_LOCAL_PATH swaps in a checkout, which is how this suite's own
// logic is verified while no tag exists yet. It is deliberately not the default,
// and it cannot pass unnoticed: a path dependency writes no `Package.resolved`
// entry, and `scripts/run.sh` refuses to call a run without one an integration
// pass. The directory has to be named `sdk-swift`, because SwiftPM takes a local
// package's identity from its directory name and the product below names it.
let sdk: Package.Dependency =
    if let local = ProcessInfo.processInfo.environment["INTERNETDATA_SDK_LOCAL_PATH"] {
        .package(path: local)
    } else {
        .package(url: "https://github.com/internetdata/sdk-swift.git", "1.0.0"..<"2.0.0")
    }

let package = Package(
    name: "internetdata-integration",
    platforms: [.macOS(.v13)],
    dependencies: [
        sdk,
        // The recording transport needs the same pieces the library builds its
        // default one from, and swift-crypto is the digest the download half
        // checks the transferred bytes against. All four are already in the
        // library's own graph, so none of them widens what gets resolved.
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.12.1"),
        .package(url: "https://github.com/apple/swift-http-types", from: "1.4.0"),
        .package(url: "https://github.com/swift-server/swift-openapi-async-http-client", from: "1.5.0"),
        .package(url: "https://github.com/swift-server/async-http-client", from: "1.36.1"),
        .package(url: "https://github.com/apple/swift-crypto", "3.0.0"..<"5.0.0"),
    ],
    targets: [
        .testTarget(
            name: "IntegrationTests",
            dependencies: [
                .product(name: "InternetData", package: "sdk-swift"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "OpenAPIAsyncHTTPClient", package: "swift-openapi-async-http-client"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
        ),
    ],
)
