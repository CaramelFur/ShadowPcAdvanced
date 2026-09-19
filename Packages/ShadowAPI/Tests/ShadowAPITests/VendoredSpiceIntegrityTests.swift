import CryptoKit
import XCTest

/// spice-html5 is LGPL and must ship unmodified; the manifest is written by
/// Scripts/vendor-spice.sh.
final class VendoredSpiceIntegrityTests: XCTestCase {
    /// <repo>/App/Resources/web/spice-html5, found relative to this file.
    private var spiceDir: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() } // → repo root
        return url.appendingPathComponent("App/Resources/web/spice-html5")
    }

    func testLicenseFilesShip() {
        for name in ["src/main.js", "COPYING", "COPYING.LESSER", "VENDORED.md"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: spiceDir.appendingPathComponent(name).path), name)
        }
    }

    func testVendoredTreeMatchesManifest() throws {
        let manifest = try String(contentsOf: spiceDir.appendingPathComponent("spice-html5.sha256"), encoding: .utf8)
        let lines = manifest.split(separator: "\n")
        XCTAssertGreaterThan(lines.count, 20)
        for line in lines {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            XCTAssertEqual(parts.count, 2)
            let path = parts[1].trimmingCharacters(in: .whitespaces)
            let data = try Data(contentsOf: spiceDir.appendingPathComponent(path))
            let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(hex, String(parts[0]), "modified vendored file: \(path)")
        }
    }
}
