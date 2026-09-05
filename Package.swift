// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "InternetData",
    // Swift concurrency ships in the OS from these releases rather than through
    // the back-deployment shim, and `Duration` (the honored `Retry-After`)
    // arrives in the same set.
    platforms: [
        .macOS(.v13), .iOS(.v16), .tvOS(.v16), .watchOS(.v9), .visionOS(.v1),
    ],
    products: [
        .library(name: "InternetData", targets: ["InternetData"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.13.1"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.12.1"),
        .package(url: "https://github.com/apple/swift-http-types", from: "1.4.0"),
        .package(url: "https://github.com/swift-server/swift-openapi-async-http-client", from: "1.5.0"),
        .package(url: "https://github.com/swift-server/async-http-client", from: "1.36.1"),
        // Test only: a pair of local HTTP origins that prove the download
        // endpoint's redirect is never followed. Already in the graph via
        // async-http-client, so declaring it costs a consumer nothing.
        .package(url: "https://github.com/apple/swift-nio", from: "2.102.0"),
    ],
    targets: [
        .target(
            name: "InternetData",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "OpenAPIAsyncHTTPClient", package: "swift-openapi-async-http-client"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
            ],
            plugins: [
                .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator"),
            ],
        ),
        .testTarget(
            name: "InternetDataTests",
            dependencies: [
                "InternetData",
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "OpenAPIAsyncHTTPClient", package: "swift-openapi-async-http-client"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
        ),
    ],
)
