import XCTest
@testable import ShadowAPI

final class ConsoleSessionTests: XCTestCase {
    func address(session: Any? = 1, ip: String = "1.2.3.4", port: Int = 2443, proximus: String? = nil) -> VMAddress {
        var d: [String: Any] = ["ip": ip, "port": port]
        if let session { d["vm_session_id"] = session }
        if let proximus { d["proximus_url"] = proximus }
        return VMAddress(json: JSONValue(any: d))!
    }

    func testSessionKeyFollowsSessionAndProxy() {
        XCTAssertEqual(address().sessionKey, address().sessionKey)
        XCTAssertNotEqual(address(session: 1).sessionKey, address(session: 2).sessionKey)
        XCTAssertNotEqual(address(ip: "1.2.3.4").sessionKey, address(ip: "1.2.3.5").sessionKey)
        XCTAssertNotEqual(address(port: 2443).sessionKey, address(port: 3443).sessionKey)
        XCTAssertNotEqual(address(proximus: "https://a.test/2").sessionKey, address(proximus: "https://b.test/2").sessionKey)
        // With a session id and a proxy URL, the raw host is not part of the identity…
        XCTAssertEqual(address(ip: "1.2.3.4", proximus: "https://a.test/2").sessionKey, address(ip: "1.2.3.5", proximus: "https://a.test/2").sessionKey)
        // …without an id it is all there is to tell two sessions apart.
        XCTAssertNotEqual(
            address(session: nil, ip: "1.2.3.4", proximus: "https://a.test/2").sessionKey,
            address(session: nil, ip: "1.2.3.5", proximus: "https://a.test/2").sessionKey
        )
        // Same proxy, written with and without the trailing slash.
        XCTAssertEqual(address(proximus: "https://a.test/2/").sessionKey, address(proximus: "https://a.test/2").sessionKey)
    }

    func testConnectsOncePerSession() {
        var tracker = ConsoleSessionTracker()
        XCTAssertEqual(tracker.observe(address: nil, stopping: false), .none)
        XCTAssertEqual(tracker.observe(address: address(), stopping: false), .began(address()))
        // Every later refresh of the same session: nothing to do, however the first connect went.
        XCTAssertEqual(tracker.observe(address: address(), stopping: false), .none)
        XCTAssertEqual(tracker.observe(address: address(), stopping: false), .none)
        XCTAssertEqual(tracker.address, address())
    }

    func testRestartIsANewSessionEvenWhenTheStopWasNeverSeen() {
        var tracker = ConsoleSessionTracker()
        _ = tracker.observe(address: address(session: 1), stopping: false)
        XCTAssertEqual(tracker.observe(address: address(session: 2), stopping: false), .began(address(session: 2)))
        XCTAssertEqual(tracker.observe(address: address(session: 2), stopping: false), .none)
        XCTAssertEqual(tracker.address?.sessionID, "2")
    }

    func testStoppingEndsAtOnceAndAFailedStopReconnects() {
        var tracker = ConsoleSessionTracker()
        _ = tracker.observe(address: address(), stopping: false)
        // The address is still there while the VM shuts down; the console URL is already worthless.
        XCTAssertEqual(tracker.observe(address: address(), stopping: true), .ended)
        XCTAssertNil(tracker.address)
        XCTAssertEqual(tracker.observe(address: address(), stopping: true), .none)
        XCTAssertEqual(tracker.observe(address: nil, stopping: true), .none)
        // Stop failed, the VM lives on: bind again (the caller mints a new ticket).
        XCTAssertEqual(tracker.observe(address: address(), stopping: false), .began(address()))
    }

    func testStopThenStartWithAnIdenticalAddressStillReconnects() {
        var tracker = ConsoleSessionTracker(missingGrace: 0)
        _ = tracker.observe(address: address(session: nil), stopping: false)
        XCTAssertEqual(tracker.observe(address: nil, stopping: false), .ended)
        XCTAssertEqual(tracker.observe(address: address(session: nil), stopping: false), .began(address(session: nil)))
    }

    func testOneMissingAddressDoesNotKickALiveConsole() {
        var tracker = ConsoleSessionTracker(missingGrace: 8)
        let t0 = Date(timeIntervalSince1970: 1_000)
        _ = tracker.observe(address: address(), stopping: false, now: t0)
        XCTAssertEqual(tracker.observe(address: nil, stopping: false, now: t0.addingTimeInterval(10)), .none)
        // Back on the next refresh: same session, the console was never touched.
        XCTAssertEqual(tracker.observe(address: address(), stopping: false, now: t0.addingTimeInterval(20)), .none)
        // Missing again, and still missing a refresh later: the VM is really gone.
        XCTAssertEqual(tracker.observe(address: nil, stopping: false, now: t0.addingTimeInterval(30)), .none)
        XCTAssertEqual(tracker.observe(address: nil, stopping: false, now: t0.addingTimeInterval(32)), .none)
        XCTAssertEqual(tracker.observe(address: nil, stopping: false, now: t0.addingTimeInterval(40)), .ended)
        XCTAssertEqual(tracker.observe(address: nil, stopping: false, now: t0.addingTimeInterval(50)), .none)
    }

    func testAdoptedSessionIsNotAnnouncedAgain() {
        var tracker = ConsoleSessionTracker()
        _ = tracker.observe(address: address(session: 1), stopping: false)
        // Reconnect found session 2 before the list did.
        tracker.adopt(address(session: 2))
        XCTAssertEqual(tracker.observe(address: address(session: 2), stopping: false), .none)
    }
}
