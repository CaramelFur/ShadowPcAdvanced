import XCTest
@testable import ShadowAPI

final class PrimitivesTests: XCTestCase {
    func testDeviceUUIDVector() {
        // node: sha1(hex(sha256(lowercased uuid)))
        XCTAssertEqual(
            DeviceUUID.derive(fromMachineID: "00000000-0000-1000-8000-AABBCCDDEEFF"),
            "4413f087dd6c069952a4a2061d20d21561c6e29a"
        )
    }

    func testPKCEVectorRFC7636() {
        XCTAssertEqual(
            PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
        let t = PKCE.randomToken(bytes: 32)
        XCTAssertEqual(t.count, 43)
        XCTAssertNil(t.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
    }

    func testTokenSetMillisecondRoundTrip() throws {
        let json = #"{"access_token":"a","refresh_token":"r","id_token":"i","token_type":"bearer","scope":"openid","expires_at":1789000000123}"#
        let t = try JSONDecoder().decode(TokenSet.self, from: Data(json.utf8))
        XCTAssertEqual(t.expiresAt.timeIntervalSince1970, 1_789_000_000.123, accuracy: 0.001)
        let back = JSONValue(data: try JSONEncoder().encode(t))
        XCTAssertEqual(back?["expires_at"]?.double, 1_789_000_000_123)
        XCTAssertEqual(back?["refresh_token"]?.string, "r")
    }

    func testTokenSetFromResponseExpiresSixtySecondsEarly() {
        let now = Date(timeIntervalSince1970: 1000)
        let t = TokenSet(tokenResponse: JSONValue(any: ["access_token": "a", "expires_in": 3600]), now: now)
        XCTAssertEqual(t?.expiresAt, now.addingTimeInterval(3540))
        XCTAssertNil(TokenSet(tokenResponse: JSONValue(any: ["error": "x"])))
    }

    func testCallbackParsing() throws {
        let ok = "tech.shadow://openidconnect/callback?code=abc%2F123&scope=openid+email&state=S1"
        XCTAssertEqual(try OAuthClient.parseCallback(ok, expectedState: "S1"), "abc/123")
        XCTAssertEqual(try OAuthClient.parseCallback("  barecode  ", expectedState: "S1"), "barecode")
        XCTAssertThrowsError(try OAuthClient.parseCallback(ok, expectedState: "other")) {
            XCTAssertEqual($0 as? ShadowError, .stateMismatch)
        }
        // A URL without any state must not be accepted.
        XCTAssertThrowsError(try OAuthClient.parseCallback("tech.shadow://openidconnect/callback?code=abc", expectedState: "S1"))
        XCTAssertThrowsError(try OAuthClient.parseCallback("tech.shadow://x?error=access_denied&error_description=nope&state=S1", expectedState: "S1")) {
            XCTAssertEqual($0 as? ShadowError, .oauth("access_denied nope"))
        }
        XCTAssertThrowsError(try OAuthClient.parseCallback("", expectedState: "S1"))
    }

    func testFormEncoding() {
        XCTAssertEqual(
            HTTPClient.formEncode([("redirect_uri", "tech.shadow://openidconnect/callback"), ("scope", "openid email")]),
            "redirect_uri=tech.shadow%3A%2F%2Fopenidconnect%2Fcallback&scope=openid%20email"
        )
    }

    func testProxyBase() {
        let legacy = VMAddress(json: JSONValue(any: ["data": ["ip": "1.2.3.4", "port": 2443, "vm_session_id": 77]]))
        XCTAssertEqual(legacy?.proxyBase?.absoluteString, "https://1.2.3.4/2")
        XCTAssertEqual(legacy?.sessionID, "77")
        let modern = VMAddress(json: JSONValue(any: ["ip": "1.2.3.4", "port": 2443, "proximus_url": "https://x.compute.shadow.tech/2/"]))
        XCTAssertEqual(modern?.proxyBase?.absoluteString, "https://x.compute.shadow.tech/2")
        XCTAssertNil(VMAddress(json: JSONValue(any: ["data": ["port": 1]])))
    }

    func testLenientVMDecoding() {
        let entries = JSONValue(any: ["pagination": [:], "entries": [
            ["id": "a", "name": "One", "status": NSNull(), "datacenter": ["name": "frsbg01"], "hwconfig": "power"],
            ["id": "b", "name": "Two", "status": ["vm_status": "started", "reachable": true, "streamer_up": false]],
            ["id": "c", "status": "starting", "maintenance": true],
            ["name": "no id"],
        ]])
        let vms = VM.list(from: entries)
        XCTAssertEqual(vms.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(vms[0].state(address: nil), .stopped)
        XCTAssertEqual(vms[0].datacenter, "frsbg01")
        XCTAssertEqual(vms[1].state(address: nil), .running)
        XCTAssertEqual(vms[1].signals?.reachable, true)
        XCTAssertEqual(vms[2].state(address: nil), .maintenance)
        XCTAssertEqual(vms[2].name, "c")
        XCTAssertEqual(VM.list(from: JSONValue(any: [["id": "x"]])).count, 1)
        XCTAssertEqual(VM.list(from: JSONValue(any: ["data": [["id": "y"]]])).count, 1)
        XCTAssertEqual(VMState(status: "reboot"), .unknown("reboot"))
    }

    func testStatusSignalsLabel() {
        XCTAssertEqual(VMStatusSignals(vmStatus: "started", reachable: true, streamerUp: true).label, "started · streamer up")
        XCTAssertEqual(VMStatusSignals(vmStatus: nil, reachable: true, streamerUp: false).label, "reachable")
        XCTAssertNil(VMStatusSignals(vmStatus: nil, reachable: false, streamerUp: false).label)
    }

    func testRedaction() {
        let jwt = "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.c2lnbmF0dXJlc2lnbmF0dXJl"
        let h = Redactor.headers(["Authorization": "Bearer \(jwt)", "Accept": "application/json"])
        XCTAssertEqual(h["Authorization"], "Bearer eyJh…(\(jwt.count))")
        XCTAssertEqual(h["Accept"], "application/json")

        let body = #"{"data":{"id":"c1","spice_secret":"hunter2hunter2","nested":[{"token":"tok_abcdefghijkl"}],"note":"\#(jwt)"}}"#
        let red = Redactor.body(Data(body.utf8), contentType: "application/json") ?? ""
        XCTAssertFalse(red.contains("hunter2hunter2"))
        XCTAssertFalse(red.contains("tok_abcdefghijkl"))
        XCTAssertFalse(red.contains(jwt))
        XCTAssertTrue(red.contains("\"id\" : \"c1\""))

        let form = Redactor.body(Data("grant_type=refresh_token&refresh_token=supersecretvalue&client_id=abc".utf8), contentType: "application/x-www-form-urlencoded") ?? ""
        XCTAssertEqual(form, "grant_type=refresh_token&refresh_token=supe…(16)&client_id=abc")

        let url = Redactor.url(URL(string: "https://auth.test/cb?code=verysecretcode&state=statestate&x=1")!)
        XCTAssertFalse(url.contains("verysecretcode"))
        XCTAssertTrue(url.contains("x=1"))
    }
}
