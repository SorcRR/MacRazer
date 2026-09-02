// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

/// End-to-end cover for `UpdateInstaller.installInPlace` against real disk images.
///
/// Heavier than the rest of the suite — it builds app bundles, ad-hoc signs them and wraps
/// them in DMGs — and deliberately so: this is the one code path that *deletes the user's
/// installed application*, and its safety rests entirely on refusals that a pure unit test of
/// `UpdatePayloadCheck` cannot exercise. Every case below asserts the same thing after a
/// refusal: the installed bundle is still there, still the old version.
///
/// Needs only base-system tools (`codesign`, `hdiutil`, `ditto`), so it runs in CI.
final class UpdateInstallerTests: XCTestCase {
    private var root: URL!
    private let bundleID = "com.macrazer.test"

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MacRazerInstallerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    /// A minimal but genuinely signed `.app`: the signature check is one of the things under
    /// test, so the fixture has to carry a real seal, not a plausible-looking directory.
    private func makeApp(named name: String, version: String, bundleID: String) throws -> URL {
        let app = root.appendingPathComponent("\(name)/MacRazer.app", isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleShortVersionString": version,
            "CFBundleExecutable": "MacRazer",
            "CFBundlePackageType": "APPL",
        ]
        try (plist as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"))
        // A real Mach-O is required — codesign refuses to seal a bundle whose executable
        // isn't one. /bin/echo is tiny and always present.
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"),
                                         to: macOS.appendingPathComponent("MacRazer"))
        XCTAssertEqual(shell("/usr/bin/codesign", ["--force", "--sign", "-", app.path]), 0,
                       "fixture must be signed for the seal check to mean anything")
        return app
    }

    /// `UDRW` by default purely for speed — it builds in ~3s against ~11s for the compressed
    /// `UDZO` that releases actually ship, and these tests are about the install logic, not the
    /// image format. The happy path passes `format: "UDZO"` so the real shape is still covered
    /// end to end, checksum verification included.
    private func makeDMG(containing app: URL, named name: String, format: String = "UDRW") throws -> URL {
        let stage = root.appendingPathComponent("stage-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: app, to: stage.appendingPathComponent("MacRazer.app"))
        return try makeDMG(fromFolder: stage, named: name, format: format)
    }

    private func makeDMG(fromFolder folder: URL, named name: String, format: String = "UDRW") throws -> URL {
        let dmg = root.appendingPathComponent("\(name).dmg")
        XCTAssertEqual(shell("/usr/bin/hdiutil", [
            "create", "-volname", "MacRazerTest", "-srcfolder", folder.path,
            "-ov", "-format", format, "-quiet", dmg.path,
        ]), 0)
        return dmg
    }

    @discardableResult
    private func shell(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    private func version(of app: URL) -> String? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?
            .value(forKey: "CFBundleShortVersionString") as? String
    }

    private func install(_ dmg: URL, into target: URL, expecting bundleID: String? = nil,
                         current: String = "1.0.0") throws -> String {
        try UpdateInstaller.installInPlace(
            dmg: dmg, into: target,
            expectedBundleID: bundleID ?? self.bundleID, currentVersion: current)
    }

    // MARK: - The happy path

    func testReplacesTheInstalledBundleWithTheNewerOne() throws {
        let installed = try makeApp(named: "installed", version: "1.0.0", bundleID: bundleID)
        let dmg = try makeDMG(containing: try makeApp(named: "new", version: "2.0.0", bundleID: bundleID),
                              named: "newer", format: "UDZO") // the format releases actually ship

        let reported = try install(dmg, into: installed)

        XCTAssertEqual(reported, "2.0.0")
        XCTAssertEqual(version(of: installed), "2.0.0", "the bundle on disk was actually swapped")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: installed.appendingPathComponent("Contents/MacOS/MacRazer").path))
        XCTAssertEqual(shell("/usr/bin/codesign", ["--verify", "--strict", installed.path]), 0,
                       "the replacement must still be a sealed bundle macOS will run")
        // A leaked mount would accumulate a phantom disk per update for the rest of the session.
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/Volumes/MacRazerTest"))
    }

    // MARK: - Refusals: each must leave the installed app untouched

    func testRefusesAnOlderPayload() throws {
        let installed = try makeApp(named: "installed", version: "1.0.0", bundleID: bundleID)
        let dmg = try makeDMG(containing: try makeApp(named: "old", version: "0.9.0", bundleID: bundleID),
                              named: "older")
        XCTAssertThrowsError(try install(dmg, into: installed)) {
            XCTAssertEqual($0 as? UpdateInstallError, .rejected(.notNewer("0.9.0")))
        }
        XCTAssertEqual(version(of: installed), "1.0.0")
    }

    func testRefusesTheSameVersion() throws {
        let installed = try makeApp(named: "installed", version: "1.0.0", bundleID: bundleID)
        let dmg = try makeDMG(containing: try makeApp(named: "same", version: "1.0.0", bundleID: bundleID),
                              named: "same")
        XCTAssertThrowsError(try install(dmg, into: installed)) {
            XCTAssertEqual($0 as? UpdateInstallError, .rejected(.notNewer("1.0.0")))
        }
        XCTAssertEqual(version(of: installed), "1.0.0")
    }

    func testRefusesADifferentApp() throws {
        // A mis-attached release asset must not overwrite MacRazer with something else.
        let installed = try makeApp(named: "installed", version: "1.0.0", bundleID: bundleID)
        let dmg = try makeDMG(
            containing: try makeApp(named: "other", version: "9.9.9", bundleID: "com.example.other"),
            named: "other")
        XCTAssertThrowsError(try install(dmg, into: installed)) {
            XCTAssertEqual($0 as? UpdateInstallError, .rejected(.wrongApp))
        }
        XCTAssertEqual(version(of: installed), "1.0.0")
    }

    func testRefusesATamperedPayload() throws {
        // What a corrupted-but-mountable download looks like: the bundle changed after it was
        // signed, so the seal no longer covers it.
        let installed = try makeApp(named: "installed", version: "1.0.0", bundleID: bundleID)
        let payload = try makeApp(named: "tampered", version: "2.0.0", bundleID: bundleID)
        let exe = payload.appendingPathComponent("Contents/MacOS/MacRazer")
        // Overwrite *inside* the executable, not past the end of it. Bytes appended after the
        // signature superblob fall outside the range the seal covers, so they validate fine —
        // which is the failure mode a first draft of this test walked straight into.
        let size = (try FileManager.default.attributesOfItem(atPath: exe.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 8192, "fixture executable is too small to corrupt meaningfully")
        let handle = try FileHandle(forWritingTo: exe)
        try handle.seek(toOffset: UInt64(size / 2))
        handle.write(Data(repeating: 0x41, count: 256))
        try handle.close()
        let dmg = try makeDMG(containing: payload, named: "tampered")

        XCTAssertThrowsError(try install(dmg, into: installed)) {
            XCTAssertEqual($0 as? UpdateInstallError, .signatureInvalid)
        }
        XCTAssertEqual(version(of: installed), "1.0.0")
    }

    func testRefusesAnUnmountableImage() throws {
        let installed = try makeApp(named: "installed", version: "1.0.0", bundleID: bundleID)
        let junk = root.appendingPathComponent("corrupt.dmg")
        try Data((0..<200_000).map { _ in UInt8.random(in: 0...255) }).write(to: junk)
        XCTAssertThrowsError(try install(junk, into: installed)) {
            XCTAssertEqual($0 as? UpdateInstallError, .mountFailed)
        }
        XCTAssertEqual(version(of: installed), "1.0.0")
    }

    func testRefusesAnImageWithNoAppInIt() throws {
        let installed = try makeApp(named: "installed", version: "1.0.0", bundleID: bundleID)
        let stage = root.appendingPathComponent("empty-stage", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try Data("not an app".utf8).write(to: stage.appendingPathComponent("README.txt"))
        let dmg = try makeDMG(fromFolder: stage, named: "empty")

        XCTAssertThrowsError(try install(dmg, into: installed)) {
            XCTAssertEqual($0 as? UpdateInstallError, .noAppInImage)
        }
        XCTAssertEqual(version(of: installed), "1.0.0")
    }
}
