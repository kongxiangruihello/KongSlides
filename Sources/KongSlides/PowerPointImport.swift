import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

extension PowerPoint {
    struct ImportedDeck {
        let deck: Deck
        let approximatedSlides: [Int]
    }

    static func read(_ url: URL, prepareImage: (Data) -> Data?) throws -> ImportedDeck {
        let archive = PresentationArchive(url: url)
        let root = try archive.xml("ppt/presentation.xml")
        guard let size = root.child("sldSz"),
              let cx = size.number("cx"), let cy = size.number("cy"), (1...200_000_000).contains(cx), (1...200_000_000).contains(cy),
              let slideIDs = root.child("sldIdLst")?.children(named: "sldId"),
              (1...500).contains(slideIDs.count) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let factor = min(960 / cx, 540 / cy)
        let widthInset = (960 - cx * factor) / 2
        let heightInset = (540 - cy * factor) / 2
        let rootLinks = try archive.links(from: "ppt/presentation.xml")
        var draft = Deck(slides: [])
        var approximation: [Int] = []
        var imageIDs: [String: UUID] = [:]

        for (index, slideID) in slideIDs.enumerated() {
            guard let relation = slideID.attribute(forLocalName: "id", uri: OfficeNamespace.relationships)?.stringValue,
                  let path = rootLinks[relation]?.path else { throw CocoaError(.fileReadCorruptFile) }
            let xml = try archive.xml(path)
            guard let content = xml.child("cSld"), let objects = content.child("spTree") else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let links = try archive.links(from: path, optional: true)
            var slide = Slide(background: content.child("bg")?.child("bgPr")?.rgbFill ?? "FFFFFF")
            var didApproximate = abs(cx / cy - 16.0 / 9.0) > 0.002 ||
                content.child("bg") != nil && content.child("bg")?.child("bgPr")?.rgbFill == nil
            if let notes = links.values.first(where: { $0.type == "notesSlide" }) {
                let notesXML = try archive.xml(notes.path)
                let noteShapes = notesXML.child("cSld")?.child("spTree")?.children(named: "sp") ?? []
                slide.speakerNotes = noteShapes.first(where: { $0.placeholderType == "body" })?
                    .child("txBody")?.plainText ?? ""
            }
            for element in objects.elementChildren {
                let name = element.localName
                if name == "nvGrpSpPr" || name == "grpSpPr" { continue }
                guard name == "sp" || name == "pic" else { didApproximate = true; continue }
                let properties = element.child("spPr")
                let transform = properties?.child("xfrm")
                let origin = transform?.child("off")
                let extent = transform?.child("ext")
                var object = SlideObject()
                if let x = origin?.number("x"), let y = origin?.number("y"),
                   let width = extent?.number("cx"), let height = extent?.number("cy"),
                   abs(x * factor) <= 9_000, abs(y * factor) <= 9_000,
                   width > 0, width * factor <= 10_000, height > 0, height * factor <= 10_000 {
                    object.x = x * factor + widthInset
                    object.y = y * factor + heightInset
                    object.width = max(1, width * factor)
                    object.height = max(1, height * factor)
                } else {
                    didApproximate = true
                    object.y = slide.objects.isEmpty ? 72 : min(390, 72 + Double(slide.objects.count) * 112)
                    object.height = slide.objects.isEmpty ? 100 : 140
                }
                if transform?.unqualifiedAttribute("rot") != nil ||
                   transform?.unqualifiedAttribute("flipH") != nil ||
                   transform?.unqualifiedAttribute("flipV") != nil { didApproximate = true }

                if name == "pic" {
                    guard let ref = element.child("blipFill")?.child("blip")?
                        .attribute(forLocalName: "embed", uri: OfficeNamespace.relationships)?.stringValue,
                          let imagePath = links[ref]?.path else { didApproximate = true; continue }
                    if imageIDs[imagePath] == nil {
                        guard let bytes = try archive.part(imagePath, maximum: 48 * 1024 * 1024, optional: true),
                              let png = prepareImage(bytes) else { didApproximate = true; continue }
                        let id = UUID()
                        imageIDs[imagePath] = id
                        draft.images[id] = png
                    }
                    object.kind = .image
                    object.imageID = imageIDs[imagePath]
                    if element.child("blipFill")?.child("srcRect") != nil { didApproximate = true }
                    slide.objects.append(object)
                    continue
                }

                let textBody = element.child("txBody")
                let text = textBody?.plainText ?? ""
                let fill = properties?.rgbFill
                let preset = properties?.child("prstGeom")?.unqualifiedAttribute("prst")?.stringValue
                if let preset, preset != "rect" { didApproximate = true }
                if properties?.child("ln")?.child("solidFill") != nil ||
                   properties?.child("gradFill") != nil || properties?.child("custGeom") != nil ||
                   element.child("style") != nil { didApproximate = true }

                if let fill {
                    var background = object
                    background.id = UUID()
                    background.kind = .rectangle
                    background.color = fill
                    slide.objects.append(background)
                }
                if !text.isEmpty {
                    object.text = text
                    let runs = textBody?.children(named: "p").flatMap { $0.children(named: "r") } ?? []
                    let firstStyle = runs.first?.child("rPr")
                    if let size = firstStyle?.number("sz") {
                        object.fontSize = min(200, max(8, size / 100 * (factor / (1.0 / 12_700))))
                    } else {
                        object.fontSize = slide.objects.isEmpty ? 46 : 30
                        didApproximate = true
                    }
                    object.bold = ["1", "true"].contains(firstStyle?.unqualifiedAttribute("b")?.stringValue ?? "")
                    object.color = firstStyle?.rgbFill ?? Palette.ink
                    if let firstStyle, runs.contains(where: { $0.child("rPr")?.xmlString != firstStyle.xmlString }) {
                        didApproximate = true
                    }
                    if element.placeholderType != nil || (textBody?.children(named: "p").contains {
                        let paragraph = $0.child("pPr")
                        return paragraph?.child("buChar") != nil || paragraph?.child("buAutoNum") != nil ||
                            ["ctr", "r", "just", "dist"].contains(paragraph?.unqualifiedAttribute("algn")?.stringValue ?? "")
                    } ?? false) { didApproximate = true }
                    slide.objects.append(object)
                } else if fill == nil {
                    didApproximate = true
                }
            }
            if xml.child("timing") != nil || xml.child("transition") != nil { didApproximate = true }
            if didApproximate { approximation.append(index + 1) }
            draft.slides.append(slide)
        }
        return ImportedDeck(deck: try draft.validated(), approximatedSlides: approximation)
    }
}

private enum OfficeNamespace {
    static let relationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
}

private final class PresentationArchive {
    let url: URL
    private var remaining = 192 * 1024 * 1024

    init(url: URL) { self.url = url }

    func xml(_ path: String) throws -> XMLElement {
        guard let data = try part(path, maximum: 4 * 1024 * 1024),
              let root = try xmlDocument(data).rootElement()?.copy() as? XMLElement else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return root
    }

    func links(from part: String, optional: Bool = false) throws -> [String: (type: String, path: String)] {
        let location = part.split(separator: "/").map(String.init)
        let folder = Array(location.dropLast())
        let path = (folder + ["_rels", (location.last ?? "") + ".rels"]).joined(separator: "/")
        guard let data = try self.part(path, maximum: 4 * 1024 * 1024, optional: optional) else { return [:] }
        let document = try xmlDocument(data)
        var result: [String: (type: String, path: String)] = [:]
        for item in document.rootElement()?.children(named: "Relationship") ?? [] {
            guard item.unqualifiedAttribute("TargetMode")?.stringValue != "External",
                  let id = item.unqualifiedAttribute("Id")?.stringValue,
                  let type = item.unqualifiedAttribute("Type")?.stringValue?.split(separator: "/").last,
                  let target = item.unqualifiedAttribute("Target")?.stringValue?.removingPercentEncoding else { continue }
            var resolved = target.hasPrefix("/") ? [] : folder
            var valid = true
            for segment in target.split(separator: "/") {
                if segment == "." { continue }
                if segment == ".." {
                    guard !resolved.isEmpty else { valid = false; break }
                    resolved.removeLast()
                } else {
                    resolved.append(String(segment))
                }
            }
            if valid && resolved.first == "ppt" {
                result[id] = (String(type), resolved.joined(separator: "/"))
            }
        }
        return result
    }

    private func xmlDocument(_ data: Data) throws -> XMLDocument {
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0"),
              !text.contains("<!DOCTYPE") else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try XMLDocument(xmlString: text, options: [.nodeLoadExternalEntitiesNever])
    }

    func part(_ path: String, maximum: Int, optional: Bool = false) throws -> Data? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/_-.")
        guard path.hasPrefix("ppt/"), !path.isEmpty,
              path.unicodeScalars.allSatisfy(allowed.contains),
              !path.split(separator: "/").contains("..") else {
            if optional { return nil }
            throw CocoaError(.fileReadCorruptFile)
        }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, path]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let input = pipe.fileHandleForReading
        defer {
            if process.isRunning { process.terminate() }
            try? input.close()
            process.waitUntilExit()
        }
        var data = Data()
        while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
            guard data.count + chunk.count <= min(maximum, remaining) else {
                throw CocoaError(.fileReadTooLarge)
            }
            data.append(chunk)
        }
        process.waitUntilExit()
        if optional && process.terminationStatus == 11 { return nil }
        guard process.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
        remaining -= data.count
        return data
    }
}

private extension XMLElement {
    var elementChildren: [XMLElement] { (children ?? []).compactMap { $0 as? XMLElement } }

    func children(named name: String) -> [XMLElement] { elementChildren.filter { $0.localName == name } }

    func child(_ name: String) -> XMLElement? { elementChildren.first { $0.localName == name } }

    func unqualifiedAttribute(_ name: String) -> XMLNode? {
        attributes?.first { $0.name == name }
    }

    func number(_ name: String) -> Double? {
        guard let raw = unqualifiedAttribute(name)?.stringValue, let value = Double(raw), value.isFinite else { return nil }
        return value
    }

    var rgbFill: String? {
        guard let hex = child("solidFill")?.child("srgbClr")?.unqualifiedAttribute("val")?.stringValue,
              hex.count == 6, Int(hex, radix: 16) != nil else { return nil }
        return hex
    }

    var placeholderType: String? {
        child("nvSpPr")?.child("nvPr")?.child("ph").map {
            $0.unqualifiedAttribute("type")?.stringValue ?? "obj"
        }
    }

    var plainText: String {
        children(named: "p").map { paragraph in
            paragraph.elementChildren.map { item in
                if item.localName == "br" { return "\n" }
                return item.child("t")?.stringValue ?? ""
            }.joined()
        }.joined(separator: "\n")
    }
}
