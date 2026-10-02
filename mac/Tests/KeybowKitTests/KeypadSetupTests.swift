@testable import KeybowKit
import XCTest

final class CircuitPythonTests: XCTestCase {
    func testVersionsInOrder() throws {
        let v = { (text: String) in try XCTUnwrap(CircuitPythonVersion(text)) }
        XCTAssertLessThan(try v("9.2.9"), try v("10.0.0"))
        XCTAssertLessThan(try v("10.0.0-beta.1"), try v("10.0.0"), "a beta before its release")
        XCTAssertLessThan(try v("10.0.0-beta.2"), try v("10.0.0-beta.10"))
        XCTAssertLessThan(try v("10.0.0-rc.0"), try v("10.0.0"))
        XCTAssertEqual(try v("10").description, "10.0.0")
        XCTAssertEqual(try v("8.2.10").description, "8.2.10")
        XCTAssertNil(CircuitPythonVersion("main"))
        XCTAssertNil(CircuitPythonVersion("1.2.3.4"))
    }

    func testWhatABoardSaysOfItself() {
        let text = """
            Adafruit CircuitPython 8.2.10 on 2024-02-14; Raspberry Pi Pico with rp2040
            Board ID:raspberry_pi_pico
            UID:E66000000000CCCC
            boot.py output:
            """
        let boot = BootOut(text: text)
        XCTAssertEqual(boot.version, CircuitPythonVersion("8.2.10"))
        XCTAssertEqual(boot.boardName, "Raspberry Pi Pico with rp2040")
        XCTAssertEqual(boot.boardID, "raspberry_pi_pico")
        XCTAssertEqual(boot.uid, "E66000000000CCCC")
        XCTAssertNil(BootOut(text: "something else").version)
    }

    func testTheNewestReleaseTheFirmwareSupports() {
        let releases = [
            CircuitPythonReleases.Release(tag: "11.0.0-alpha.1", prerelease: true),
            CircuitPythonReleases.Release(tag: "11.0.0"),
            CircuitPythonReleases.Release(tag: "10.3.1"),
            CircuitPythonReleases.Release(tag: "10.4.0-beta.0", prerelease: true),
            CircuitPythonReleases.Release(tag: "9.2.9"),
            CircuitPythonReleases.Release(tag: "10.3.0"),
            CircuitPythonReleases.Release(tag: "10.3.2", draft: true),
            CircuitPythonReleases.Release(tag: "7.3.3"),
        ]
        XCTAssertEqual(CircuitPythonReleases.candidates(releases, majors: 8...10).map(\.description),
                       ["10.3.1", "10.3.0", "9.2.9"], "no betas, drafts, or majors it isn't for")
    }

    func testDownloadsByName() throws {
        let version = try XCTUnwrap(CircuitPythonVersion("10.3.1"))
        XCTAssertEqual(CircuitPythonReleases.downloadURL(board: "raspberry_pi_pico", version: version).absoluteString,
                       "https://downloads.circuitpython.org/bin/raspberry_pi_pico/en_US/"
                       + "adafruit-circuitpython-raspberry_pi_pico-en_US-10.3.1.uf2")
        XCTAssertEqual(CircuitPythonReleases.version(ofFile: "adafruit-circuitpython-raspberry_pi_pico-en_US-9.2.9.uf2",
                                                     board: "raspberry_pi_pico"), CircuitPythonVersion("9.2.9"))
        XCTAssertNil(CircuitPythonReleases.version(ofFile: "adafruit-circuitpython-pimoroni_keybow2040-en_US-9.2.9.uf2",
                                                   board: "raspberry_pi_pico"))
    }

    /// A UF2 image of `count` blocks, as a bootloader takes them.
    private func image(blocks count: Int, family: UInt32 = UF2.rp2040) -> Data {
        var data = Data()
        for block in 0..<count {
            var bytes = [UInt8](repeating: 0, count: 512)
            func put(_ value: UInt32, at offset: Int) {
                withUnsafeBytes(of: value.littleEndian) { bytes.replaceSubrange(offset..<offset + 4, with: $0) }
            }
            put(0x0A32_4655, at: 0)
            put(0x9E5D_5157, at: 4)
            put(0x2000, at: 8)
            put(0x1000_0000 + UInt32(block) * 256, at: 12)
            put(256, at: 16)
            put(UInt32(block), at: 20)
            put(UInt32(count), at: 24)
            put(family, at: 28)
            put(0x0AB1_6F30, at: 508)
            data.append(contentsOf: bytes)
        }
        return data
    }

    func testOnlyAWholeRP2040ImageIsWritten() {
        XCTAssertNil(UF2.problem(with: image(blocks: 3), family: UF2.rp2040))
        XCTAssertEqual(UF2.problem(with: Data("<html>Not found</html>".utf8), family: UF2.rp2040), "it isn't a UF2 file")
        XCTAssertEqual(UF2.problem(with: image(blocks: 3, family: 0xE48B_FF59), family: UF2.rp2040),
                       "it's for another kind of board")
        XCTAssertEqual(UF2.problem(with: image(blocks: 4).prefix(1024), family: UF2.rp2040), "it's incomplete")
        XCTAssertEqual(UF2.problem(with: Data(), family: UF2.rp2040), "it isn't a UF2 file")
    }
}

final class FirmwarePackageTests: XCTestCase {
    /// The repository's own firmware folder.
    private let package: FirmwarePackage = {
        let firmware = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("firmware")
        return try! FirmwarePackage(root: firmware)
    }()

    private var drive: URL!
    private var backup: URL!

    override func setUpWithError() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("keypad-\(UUID().uuidString)")
        drive = scratch.appendingPathComponent("CIRCUITPY")
        backup = scratch.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: drive.deletingLastPathComponent())
    }

    func testEachBoardGetsItsOwnLibraries() {
        let keybow = package.files(for: .keybow2040), rgb = package.files(for: .rgbKeypad)
        for files in [keybow, rgb] {
            XCTAssertEqual(Array(files.prefix(3)), ["boot.py", "code.py", "keymap.py"])
            XCTAssertTrue(files.contains("lib/pmk/__init__.py"))
            XCTAssertTrue(files.contains("lib/pmk/platform/rgbkeypadbase.py"), "folders, all the way down")
        }
        XCTAssertTrue(keybow.contains("lib/adafruit_is31fl3731/keybow2040.py"))
        XCTAssertFalse(keybow.contains("lib/adafruit_dotstar.py"))
        XCTAssertTrue(rgb.contains("lib/adafruit_dotstar.py"))
        XCTAssertFalse(rgb.contains { $0.hasPrefix("lib/adafruit_is31fl3731") })
        XCTAssertFalse(keybow.contains { $0.hasSuffix("README.md") }, "only what the manifest names")
        XCTAssertEqual(package.model(forCircuitPythonBoard: "raspberry_pi_pico"), .rgbKeypad)
        XCTAssertEqual(package.model(forCircuitPythonBoard: "pimoroni_keybow2040"), .keybow2040)
        XCTAssertEqual(package.majors.lowerBound, 8)
    }

    func testInstallingKeepsWhatItReplaces() throws {
        try Data("print('hello')\n".utf8).write(to: drive.appendingPathComponent("code.py"))
        try Data("print('first')\n".utf8).write(to: drive.appendingPathComponent("code.txt"))
        try Data("CIRCUITPY_WEB_API_PORT = 80\n".utf8).write(to: drive.appendingPathComponent("settings.toml"))
        XCTAssertEqual(package.status(on: drive, model: .rgbKeypad), .other)

        let installed = try package.install(model: .rgbKeypad, on: drive, backup: backup)
        XCTAssertEqual(installed.written.count, package.files(for: .rgbKeypad).count)
        XCTAssertEqual(installed.written.last, "code.py", "code.py last, once what it imports is there")
        XCTAssertEqual(installed.backedUp.sorted(), ["code.py", "code.txt"])
        XCTAssertEqual(try String(contentsOf: backup.appendingPathComponent("code.py"), encoding: .utf8), "print('hello')\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: drive.appendingPathComponent("code.txt").path),
                       "code.txt would run instead of code.py")
        XCTAssertTrue(FileManager.default.fileExists(atPath: drive.appendingPathComponent("settings.toml").path),
                      "the rest is left alone")
        XCTAssertEqual(try Data(contentsOf: drive.appendingPathComponent("lib/adafruit_dotstar.py")),
                       try Data(contentsOf: package.root.appendingPathComponent("lib/adafruit_dotstar.py")))
        XCTAssertEqual(package.status(on: drive, model: .rgbKeypad), .current)
    }

    func testAnUpToDateBoardIsLeftAsItIs() throws {
        _ = try package.install(model: .keybow2040, on: drive, backup: backup)
        try? FileManager.default.removeItem(at: backup)
        let again = try package.install(model: .keybow2040, on: drive, backup: backup)
        XCTAssertEqual(again, FirmwarePackage.Installed())
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path), "no backup folder for nothing")
    }

    func testOlderFirmwareIsKnownForWhatItIs() throws {
        _ = try package.install(model: .keybow2040, on: drive, backup: backup)
        try Data("# HELLO keybow 1\n".utf8).write(to: drive.appendingPathComponent("code.py"))
        XCTAssertEqual(package.status(on: drive, model: .keybow2040), .older)
        let installed = try package.install(model: .keybow2040, on: drive, backup: backup)
        XCTAssertEqual(installed.written, ["code.py"], "only what's changed")
    }
}
