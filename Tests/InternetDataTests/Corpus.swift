import Foundation
import Testing

@testable import InternetData

/// The shared conformance corpus that every InternetData SDK asserts.
///
/// Generated into `testdata/` and identical across languages, so a behavior that
/// drifts here fails here rather than surfacing as two client libraries quietly
/// disagreeing about the same refusal.
///
/// Much smaller than VPNDetection's, and that is the point: this API has no
/// per-IP lookup, so there is no bogon table, no tier ladder and no batch to
/// pin. What is left is error mapping, which is exactly where the VPNDetection
/// SDKs drifted, and the vocabularies the database endpoints answer with.
struct Corpus: Decodable, Sendable {
    let errors: [ErrorCase]
    let standings: [String]
    let license_type: [String]
    let formats: [String]
    let visibility: Visibility

    struct ErrorCase: Decodable, Sendable {
        let name: String
        let status: Int
        let headers: [String: String]
        let body: JSONValue
        let expect: Expect

        struct Expect: Decodable, Sendable {
            let kind: String
            let retryable: Bool
            let message: String?
            let retryAfterSeconds: Int?
        }
    }

    struct Visibility: Decodable, Sendable {
        let why: String
        /// What a client must do about it. Named rather than exemplified: the
        /// private families are deliberately not listed, because this corpus is
        /// committed into twelve PUBLIC repositories.
        let clientRules: [String]
    }
}

extension Corpus {
    // Located from the source file rather than from a bundle: the corpus is
    // regenerated into the repository root by sdk/common, which is outside any
    // target directory and so cannot be declared as a SwiftPM resource.
    static let shared: Corpus = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let path = root.appendingPathComponent("testdata/testdata.json")
        guard let data = try? Data(contentsOf: path),
            let corpus = try? JSONDecoder().decode(Corpus.self, from: data)
        else {
            fatalError("could not read the conformance corpus at \(path.path)")
        }
        return corpus
    }()
}

extension JSONValue {
    /// The fixture body as the bytes a server would have sent.
    var encoded: Data {
        guard let data = try? JSONEncoder().encode(self) else {
            fatalError("a corpus fixture body could not be re-encoded")
        }
        return data
    }
}
