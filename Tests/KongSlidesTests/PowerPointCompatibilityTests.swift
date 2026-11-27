import XCTest
@testable import KongSlides

final class PowerPointCompatibilityTests: XCTestCase {
    func testStrictUTF16AndMovedPartsWithMissingSecondSlide() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        func part(_ name: String, _ content: String, encoding: String.Encoding = .utf8) throws {
            let target = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: target, atomically: false, encoding: encoding)
        }
        let rel = "http://purl.oclc.org/ooxml/officeDocument/relationships"
        let p = "http://purl.oclc.org/ooxml/presentationml/main"
        let a = "http://purl.oclc.org/ooxml/drawingml/main"
        let package = "http://schemas.openxmlformats.org/package/2006/relationships"
        try part("_rels/.rels", """
        <Relationships xmlns="\(package)"><Relationship Id="r1" Type="\(rel)/officeDocument" Target="/演示%20文稿/main.xml"/></Relationships>
        """)
        try part("演示 文稿/main.xml", """
        <?xml version="1.0" encoding="UTF-16"?>
        <p:presentation xmlns:p="\(p)" xmlns:r="\(rel)">
        <p:sldIdLst><p:sldId id="256" r:id="r1"/><p:sldId id="257" r:id="r2"/></p:sldIdLst>
        <p:sldSz cx="12192000" cy="6858000"/></p:presentation>
        """, encoding: .utf16)
        try part("演示 文稿/_rels/main.xml.rels", """
        <Relationships xmlns="\(package)">
        <Relationship Id="r1" Type="\(rel)/slide" Target="../页面/第一页.xml"/>
        <Relationship Id="r2" Type="\(rel)/slide" Target="../页面/missing.xml"/>
        </Relationships>
        """)
        try part("页面/第一页.xml", """
        <p:sld xmlns:p="\(p)" xmlns:a="\(a)"><p:cSld><p:spTree>
        <p:sp><p:spPr/><p:txBody><a:p><a:r><a:t>史料原文</a:t></a:r></a:p></p:txBody></p:sp>
        </p:spTree></p:cSld></p:sld>
        """)
        let archive = root.appendingPathComponent("真实结构样本.pptx")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = root
        zip.arguments = ["-q", "-r", archive.path, "_rels", "演示 文稿", "页面"]
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
        var updates: [Int] = []
        let imported = try PowerPoint.read(archive, progress: { done, total in
            XCTAssertEqual(total, 2)
            updates.append(done)
        }, prepareImage: { $0 }).deck
        XCTAssertEqual(updates, [0, 1, 2])
        XCTAssertEqual(imported.slides.count, 2)
        XCTAssertEqual(imported.slides.first?.objects.first?.text, "史料原文")
        XCTAssertEqual(imported.slides.last?.isBackup, true)
        XCTAssertEqual(imported.slides.last?.importReport?.sourcePage, 2)
        XCTAssertTrue(imported.slides.last?.importReport?.diagnostics.first?.detail.contains("missing.xml") == true)
    }

    func testPlainTextRenamedPPTXHasSpecificError() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pptx")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not a zip".utf8).write(to: url)
        XCTAssertThrowsError(try PowerPoint.read(url, prepareImage: { $0 })) { error in
            guard case PowerPointReadError.package = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }
}
