import Foundation
import KongSlidesUpdateSupport
import XCTest

final class SoftwareUpdateTests: XCTestCase {
    private let checksum = String(repeating: "a", count: 64)

    func testSelectsNewestInstallableRelease() throws {
        let current = try XCTUnwrap(AppVersion("0.1.1"))
        let offers: [[String: Any]] = [
            release("0.2.0", draft: true),
            release("0.1.10"),
            release("0.1.9"),
            release("0.2.1", host: "example.net"),
            release("0.2.2", digest: "sha256:zz"),
            release("0.2.3", state: "new"),
            release("0.2.4", host: "github.com:8443"),
            release("0.1.0"),
            release("0.1.01"),
            release("0.3.0-beta")
        ]
        let offer = try XCTUnwrap(UpdateRepository.findUpdate(in: JSONSerialization.data(withJSONObject: offers),
                                                               current: current))
        XCTAssertEqual(offer.version, AppVersion("0.1.10"))
        XCTAssertEqual(offer.sha256, checksum)
        XCTAssertEqual(offer.bytes, 15)
    }

    func testSkipsSameVersionAndDowngrade() throws {
        let current = try XCTUnwrap(AppVersion("0.1.10"))
        let data = try JSONSerialization.data(withJSONObject: [release("0.1.9"), release("0.1.10")])
        XCTAssertNil(try UpdateRepository.findUpdate(in: data, current: current))
    }

    func testVerifiesActualArchiveBytes() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        try Data("abc".utf8).write(to: path)
        let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        XCTAssertTrue(try UpdateRepository.isMatchingArchive(path, bytes: 3, sha256: expected))
        XCTAssertFalse(try UpdateRepository.isMatchingArchive(path, bytes: 4, sha256: expected))
        try Data("def".utf8).write(to: path)
        XCTAssertFalse(try UpdateRepository.isMatchingArchive(path, bytes: 3, sha256: expected))
    }

    func testAtomicallyExchangesBundlesAndCanRollBack() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let installed = folder.appendingPathComponent("KongSlides.app", isDirectory: true)
        let staged = folder.appendingPathComponent(".update/KongSlides.app", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try writeApp(installed, version: "0.1.1")
        try writeApp(staged, version: "0.1.2")
        try UpdateInstallation.install(staged, at: installed, replacing: AppVersion("0.1.1"))
        XCTAssertEqual(UpdateInstallation.version(of: installed), AppVersion("0.1.2"))
        XCTAssertEqual(UpdateInstallation.version(of: staged), AppVersion("0.1.1"))
        try UpdateInstallation.swap(installed, staged)
        XCTAssertEqual(UpdateInstallation.version(of: installed), AppVersion("0.1.1"))
        XCTAssertEqual(UpdateInstallation.version(of: staged), AppVersion("0.1.2"))
    }

    func testCanInstallAndUndoAtNewLocationWithoutTouchingOriginal() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = folder.appendingPathComponent("Downloads/KongSlides.app", isDirectory: true)
        let new = folder.appendingPathComponent("Applications/KongSlides.app", isDirectory: true)
        let staged = folder.appendingPathComponent("Applications/.staging/KongSlides.app", isDirectory: true)
        try writeApp(old, version: "0.1.2")
        try writeApp(staged, version: "0.1.3")
        XCTAssertNil(try UpdateInstallation.installedVersion(at: new))
        try UpdateInstallation.install(staged, at: new, replacing: nil)
        XCTAssertEqual(try UpdateInstallation.installedVersion(at: new), AppVersion("0.1.3"))
        XCTAssertEqual(try UpdateInstallation.installedVersion(at: old), AppVersion("0.1.2"))
        try UpdateInstallation.placeExclusively(new, at: staged)
        XCTAssertNil(try UpdateInstallation.installedVersion(at: new))
        XCTAssertEqual(try UpdateInstallation.installedVersion(at: staged), AppVersion("0.1.3"))
    }

    func testSelectedLocationProtectsUnrelatedFilesAndChangedVersions() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("KongSlides.app")
        let staged = folder.appendingPathComponent(".staging/KongSlides.app", isDirectory: true)
        try writeApp(staged, version: "0.1.3")
        let unrelated = Data("preserve".utf8)
        try unrelated.write(to: target)
        XCTAssertThrowsError(try UpdateInstallation.install(staged, at: target, replacing: nil))
        XCTAssertEqual(try Data(contentsOf: target), unrelated)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: folder.appendingPathComponent("missing"))
        XCTAssertThrowsError(try UpdateInstallation.install(staged, at: target, replacing: nil))
        try FileManager.default.removeItem(at: target)
        try writeApp(target, version: "0.1.4")
        XCTAssertThrowsError(try UpdateInstallation.install(staged, at: target, replacing: AppVersion("0.1.2")))
        XCTAssertEqual(try UpdateInstallation.installedVersion(at: target), AppVersion("0.1.4"))
    }

    func testSameParentResolvesForBothExistingStageAndVacantTarget() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let actual = folder.appendingPathComponent("Actual", isDirectory: true)
        let alias = folder.appendingPathComponent("Alias")
        let stage = actual.appendingPathComponent(".staging", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        let target = alias.appendingPathComponent("KongSlides.app", isDirectory: true)
        XCTAssertNil(try UpdateInstallation.installedVersion(at: target))
        XCTAssertEqual(UpdateInstallation.parentDirectory(of: stage).path,
                       UpdateInstallation.parentDirectory(of: target).path)
    }

    private func writeApp(_ url: URL, version: String) throws {
        let folder = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let plist = [
            "CFBundleIdentifier": "com.kongslides.app",
            "CFBundleExecutable": "KongSlides",
            "CFBundleShortVersionString": version
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: folder.appendingPathComponent("Info.plist"))
    }

    private func release(_ version: String, draft: Bool = false, host: String = "github.com",
                         digest: String? = nil, state: String = "uploaded") -> [String: Any] {
        let name = "KongSlides-\(version)-macOS-preview.zip"
        return [
            "tag_name": "v\(version)", "draft": draft, "prerelease": true,
            "assets": [[
                "name": name, "state": state, "size": 15, "digest": digest ?? "sha256:\(checksum)",
                "browser_download_url": "https://\(host)/kongxiangruihello/KongSlides/releases/download/v\(version)/\(name)"
            ]]
        ]
    }
}
