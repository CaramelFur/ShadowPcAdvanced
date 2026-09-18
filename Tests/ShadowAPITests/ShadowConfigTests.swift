import XCTest
@testable import ShadowAPI

final class ShadowConfigTests: XCTestCase {
    func testDefaults() {
        let c = ShadowConfig()
        XCTAssertEqual(c.discoveryURL.absoluteString, "https://auth.eu.shadow.tech/hydra/.well-known/openid-configuration")
        XCTAssertEqual(c.redirectScheme, "tech.shadow")
        XCTAssertTrue(c.userAgent.contains("Electron/"))
    }

    func testEnvironmentOverrides() {
        let c = ShadowConfig.fromEnvironment(["SHADOW_API_BASE": "https://example.test/v3", "OAUTH_CLIENT_ID": "abc"])
        XCTAssertEqual(c.apiBase.absoluteString, "https://example.test/v3")
        XCTAssertEqual(c.clientID, "abc")
        XCTAssertEqual(c.scope, ShadowConfig().scope)
    }
}
