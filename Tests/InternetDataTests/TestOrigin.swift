import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

/// A throwaway HTTP origin, so the redirect the download endpoint answers with
/// is exercised by the real transport rather than by a stub that cannot follow
/// anything.
///
/// An answer may promise a `Content-Length` far larger than the bytes it writes
/// and then never finish the response. A client that followed the redirect and
/// read the body would wait forever rather than merely be slow, which is the
/// point: the failure being guarded against is a multi-gigabyte transfer.
final class TestOrigin: Sendable {
    struct Answer: Sendable {
        var status: HTTPResponseStatus = .ok
        var headers: [(String, String)] = []
        var body: [UInt8] = []
        /// Leave false to stall after the body, promising more that never comes.
        var complete: Bool = true
        /// Drop the connection after the body, so a promised length never arrives.
        var closeAfterBody: Bool = false
        /// Take the request and never answer it at all, not even with a head.
        var silent: Bool = false
        /// Drop the connection this long after the request, so a stall outlasts any
        /// bound under test but a client with no bound fails an assertion rather
        /// than hanging the suite.
        var closeAfter: TimeAmount?
        /// Write the body one byte at a time, this far apart, so no single read
        /// ever waits long while the whole body takes as long as it likes.
        var trickle: TimeAmount?
    }

    let port: Int
    private let channel: any Channel
    private let group: MultiThreadedEventLoopGroup
    private let log: RequestLog

    var receivedPaths: [String] { log.paths }
    /// The `Authorization` header of every request, so "the key never left the
    /// API" is asserted at the wire rather than inferred from the code.
    var receivedAuthorizations: [String?] { log.authorizations }

    static func start(_ answer: @escaping @Sendable (String) -> Answer) async throws -> TestOrigin {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let log = RequestLog()
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 16)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(Handler(answer: answer, log: log))
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        return TestOrigin(channel: channel, group: group, log: log)
    }

    func stop() async throws {
        try? await channel.close().get()
        try await group.shutdownGracefully()
    }

    private init(channel: any Channel, group: MultiThreadedEventLoopGroup, log: RequestLog) {
        self.channel = channel
        self.group = group
        self.log = log
        self.port = channel.localAddress?.port ?? 0
    }

    // A lock rather than an actor so a request is recorded BEFORE the response
    // is written; an actor would record it in a detached task, and an assertion
    // made the instant the client returns could beat it.
    private final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [(String, String?)] = []

        var paths: [String] {
            lock.withLock { storage.map(\.0) }
        }

        var authorizations: [String?] {
            lock.withLock { storage.map(\.1) }
        }

        func record(_ path: String, authorization: String?) {
            lock.withLock { storage.append((path, authorization)) }
        }
    }

    // Event-loop confined, which is the contract NIO handlers have always had
    // and which predates Sendable.
    private final class Handler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        private let answer: @Sendable (String) -> Answer
        private let log: RequestLog
        private var uri = "/"
        private var authorization: String?

        init(answer: @escaping @Sendable (String) -> Answer, log: RequestLog) {
            self.answer = answer
            self.log = log
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case .head(let head):
                uri = head.uri
                authorization = head.headers.first(name: "Authorization")
            case .body:
                break
            case .end:
                respond(context: context)
            }
        }

        private func respond(context: ChannelHandlerContext) {
            let path = uri
            log.record(path, authorization: authorization)

            let answer = answer(path)
            if let after = answer.closeAfter {
                context.eventLoop.assumeIsolated().scheduleTask(in: after) {
                    context.close(promise: nil)
                }
            }
            guard !answer.silent else {
                return
            }
            var headers = HTTPHeaders()
            for (name, value) in answer.headers {
                headers.add(name: name, value: value)
            }
            let head = HTTPResponseHead(version: .http1_1, status: answer.status, headers: headers)
            context.write(wrapOutboundOut(.head(head)), promise: nil)
            if let every = answer.trickle {
                context.flush()
                trickle(answer.body[...], every: every, complete: answer.complete, context: context)
                return
            }
            if !answer.body.isEmpty {
                var buffer = context.channel.allocator.buffer(capacity: answer.body.count)
                buffer.writeBytes(answer.body)
                context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            }
            if answer.complete {
                context.write(wrapOutboundOut(.end(nil)), promise: nil)
            }
            context.flush()
            if answer.closeAfterBody {
                context.close(promise: nil)
            }
        }

        private func trickle(
            _ rest: ArraySlice<UInt8>, every: TimeAmount, complete: Bool, context: ChannelHandlerContext,
        ) {
            context.eventLoop.assumeIsolated().scheduleTask(in: every) {
                guard let byte = rest.first else {
                    if complete {
                        context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
                    }
                    return
                }
                var buffer = context.channel.allocator.buffer(capacity: 1)
                buffer.writeInteger(byte)
                context.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                self.trickle(rest.dropFirst(), every: every, complete: complete, context: context)
            }
        }
    }
}

extension TestOrigin.Answer {
    static func redirect(to location: String) -> Self {
        .init(status: .found, headers: [("Location", location), ("Content-Length", "0")])
    }

    /// Promises a gigabyte, writes sixteen bytes, and never ends the response.
    static var neverEndingGigabyte: Self {
        .init(
            status: .ok,
            headers: [("Content-Type", "application/octet-stream"), ("Content-Length", "1073741824")],
            body: Array(repeating: 0, count: 16),
            complete: false,
        )
    }

    /// A database that dies mid-transfer: the promised length is never delivered
    /// and the connection drops, which is the only way a half-written file
    /// appears at all.
    static func truncated(promising length: Int, writing written: Int) -> Self {
        .init(
            status: .ok,
            headers: [
                ("Content-Type", "application/octet-stream"), ("Content-Length", "\(length)"),
            ],
            body: Array(repeating: 0x41, count: written),
            complete: false,
            closeAfterBody: true,
        )
    }

    /// Takes the request and answers nothing for eight seconds, then hangs up.
    static var silence: Self {
        .init(silent: true, closeAfter: .seconds(8))
    }

    /// A JSON answer whose head arrives and whose body stops part way, until the
    /// connection drops eight seconds later.
    static var stalledJSON: Self {
        .init(
            status: .ok,
            headers: [("Content-Type", "application/json"), ("Content-Length", "64")],
            body: Array(#"{"databases":"#.utf8),
            complete: false,
            closeAfter: .seconds(8),
        )
    }

    /// A whole empty listing, served in one piece.
    static var listing: Self {
        let body = Array(#"{"databases":[]}"#.utf8)
        return .init(
            status: .ok,
            headers: [("Content-Type", "application/json"), ("Content-Length", "\(body.count)")],
            body: body,
        )
    }

    /// A whole empty listing, one byte every 20 ms: about a second in all, and
    /// never more than 20 ms between two bytes.
    static var trickledListing: Self {
        let body = Array((#"{"databases":[]"# + String(repeating: " ", count: 34) + "}").utf8)
        return .init(
            status: .ok,
            headers: [("Content-Type", "application/json"), ("Content-Length", "\(body.count)")],
            body: body,
            trickle: .milliseconds(20),
        )
    }

    /// A small database, one byte every 20 ms.
    static func trickled(_ bytes: [UInt8]) -> Self {
        .init(
            status: .ok,
            headers: [
                ("Content-Type", "application/octet-stream"), ("Content-Length", "\(bytes.count)"),
            ],
            body: bytes,
            trickle: .milliseconds(20),
        )
    }

    /// A whole small database, served in one piece.
    static func file(_ bytes: [UInt8]) -> Self {
        .init(
            status: .ok,
            headers: [
                ("Content-Type", "application/octet-stream"), ("Content-Length", "\(bytes.count)"),
            ],
            body: bytes,
        )
    }
}
