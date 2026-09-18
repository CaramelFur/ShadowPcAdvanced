import CryptoKit
import XCTest
@testable import FunkyShadowUI

/// spice-html5 is LGPL and must ship unmodified; the manifest is written by
/// Scripts/vendor-spice.sh.
final class VendoredSpiceIntegrityTests: XCTestCase {
    func testWebAssetsResolve() throws {
        let root = try XCTUnwrap(WebAssets.rootURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("spice-html5/src/main.js").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("spice-html5/COPYING.LESSER").path))
    }

    func testVendoredTreeMatchesManifest() throws {
        let spice = try XCTUnwrap(WebAssets.rootURL).appendingPathComponent("spice-html5")
        let manifest = try String(contentsOf: spice.appendingPathComponent("spice-html5.sha256"), encoding: .utf8)
        let lines = manifest.split(separator: "\n")
        XCTAssertGreaterThan(lines.count, 20)
        for line in lines {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            XCTAssertEqual(parts.count, 2)
            let path = parts[1].trimmingCharacters(in: .whitespaces)
            let data = try Data(contentsOf: spice.appendingPathComponent(path))
            let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(hex, String(parts[0]), "modified vendored file: \(path)")
        }
    }
}
