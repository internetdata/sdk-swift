import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

@testable import InternetData

/// Every request names the SDK, so its traffic and the versions still in use can
/// be counted: the API's, OAuth's and object storage's transfer alike.
@Suite("User-Agent")
struct UserAgentTests {
    static let expected = "internetdata-swift/\(sdkVersion)"

    @Test("every request names the SDK and its version, at the wire")
    func everyRequestNamesTheSDK() async throws {
        let storage = try await TestOrigin.start { _ in .file(Array("bytes".utf8)) }
        defer { Task { try? await storage.stop() } }
        let location = "http://127.0.0.1:\(storage.port)/bogon_ip_v1.csv.gz?signature=abc"
        let api = try await TestOrigin.start { path in
            switch path {
            case let path where path.hasPrefix("/api/v2/database/download"): .redirect(to: location)
            case "/api/v2/database/list": .json(#"{"databases":[]}"#)
            case "/.well-known/oauth-authorization-server": .json(OauthTests.everyRequiredMember.body)
            default: .json(StubTransport.answerJSON(for: "1.1.1.1"))
            }
        }
        defer { Task { try? await api.stop() } }
        let client = InternetDataClient(
            options: .init(apiKey: "key", baseURL: URL(string: "http://127.0.0.1:\(api.port)")!, retries: 0),
        )

        _ = try await client.lookup("1.1.1.1")
        _ = try await client.database.list()
        _ = try await client.oauth.metadata()
        _ = try await client.database.downloadBytes("bogon_ip_v1", format: .csvgz)

        #expect(api.receivedPaths.count == 4)
        #expect(api.receivedUserAgents == Array(repeating: Self.expected, count: 4))
        #expect(storage.receivedUserAgents == [Self.expected], "object storage's transfer")
    }

    @Test("a transport passed in sees the header already set, so a wrapper can put its name first")
    func aPassedTransportSeesTheHeader() async throws {
        let recorder = HeaderRecorder()
        let client = InternetDataClient(options: .init(apiKey: "key", retries: 0, transport: recorder))

        _ = try? await client.lookup("1.1.1.1")
        _ = try? await client.lookupBatch(["1.1.1.1", "8.8.8.8"])
        _ = try? await client.oauth.metadata()

        let seen = await recorder.userAgents
        #expect(seen.count == 3)
        #expect(seen.allSatisfy { $0 == Self.expected }, "\(seen)")
    }

    // The version is written into the source, since a Swift package carries no
    // version of its own: the README's pin is what the release gate holds to the
    // tag, so the two must agree.
    @Test("the version it sends is the one the README installs")
    func theVersionIsTheReadmePin() throws {
        let readme = try String(
            contentsOf: Corpus.repositoryRoot.appendingPathComponent("README.md"), encoding: .utf8,
        )
        #expect(readme.contains("from: \"\(sdkVersion)\""), "README.md pins another version than \(sdkVersion)")
    }
}

/// Records each request's `User-Agent`, and answers nothing a call could read.
final class HeaderRecorder: ClientTransport {
    private let log = Log()

    var userAgents: [String?] {
        get async { await log.userAgents }
    }

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String,
    ) async throws -> (HTTPResponse, HTTPBody?) {
        await log.record(request.headerFields[.userAgent])
        return (HTTPResponse(status: .notFound), nil)
    }

    private actor Log {
        var userAgents: [String?] = []

        func record(_ userAgent: String?) {
            userAgents.append(userAgent)
        }
    }
}
