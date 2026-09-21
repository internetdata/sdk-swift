import Foundation
import Testing
import InternetData

/// The oauth accessor against staging, on a keyless client, so none of it needs
/// the staging key or skips without it. Only calls that cannot touch anybody's
/// sign-in: discovery, revoking and exchanging codes that
/// were never issued, and ONE device authorization per run, because its limit of
/// 30 a minute is per source address and shared. Nothing polls: nobody approves
/// the code, and it expires on its own.
@Suite("Staging OAuth")
struct OauthTests {
    static let clientID = "internetdata-cli"
    static let stagingConsole = "https://app-staging.internetdata.io"

    let client = InternetDataClient(options: .init(baseURL: staging))

    @Test("metadata names staging as the issuer")
    func metadataNamesStaging() async throws {
        let metadata = try await client.oauth.metadata()

        #expect(metadata.issuer == staging.absoluteString)
        #expect(metadata.deviceAuthorizationEndpoint != nil)
        #expect(metadata.codeChallengeMethodsSupported?.contains("S256") == true)
    }

    @Test("revoke accepts a token that was never issued")
    func revokeAcceptsJunk() async throws {
        try await client.oauth.revoke("mo_rt_sdk-ci-not-a-token", clientID: Self.clientID)
    }

    @Test("a device code that was never issued is the expired-token refusal")
    func junkDeviceCodeIsExpired() async throws {
        do {
            _ = try await client.oauth.exchangeDeviceCode("mo_dc_sdk-ci-not-a-code", clientID: Self.clientID)
            Issue.record("a device code that was never issued was exchanged")
        } catch OauthError.expiredToken(let refusal) {
            #expect(refusal.status == 400)
        }
    }

    @Test("a device authorization starts a sign-in, or is told to slow down")
    func deviceAuthorizationStarts() async throws {
        do {
            let device = try await client.oauth.deviceAuthorization(
                clientID: Self.clientID, scope: "account.read",
            )

            #expect(!device.deviceCode.isEmpty, "no device_code")
            #expect(!device.userCode.isEmpty, "no user_code")
            // The console's, not the apex's: the API is served at the apex here, so a
            // page taken from the API host would be the landing page's, which a
            // `/device` suffix alone still passes.
            #expect(device.verificationURI == Self.stagingConsole + "/device")
            #expect(device.expiresIn > 0 && device.interval > 0)
        } catch OauthError.rejected(let refusal) where refusal.errorCode == "slow_down" {
            // Other runs on this address used the minute's allowance. The refusal is
            // still the accessor working.
        }
    }
}
