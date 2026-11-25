import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

extension PowerPoint {
    struct ImportedDeck {
        let deck: Deck
    }

    static func read(_ url: URL, fontAvailable: ((String) -> Bool)? = nil,
                     prepareImage: (Data) -> Data?) throws -> ImportedDeck {
        let archive = PresentationArchive(url: url)
        let root = try archive.xml("ppt/presentation.xml")
        guard let size = root.child("sldSz"),
              let cx = size.number("cx"), let cy = size.number("cy"),
              (1...200_000_000).contains(cx), (1...200_000_000).contains(cy),
              let slideIDs = root.child("sldIdLst")?.children(named: "sldId"),
              (1...500).contains(slideIDs.count) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let factor = min(960 / cx, 540 / cy)
        let widthInset = (960 - cx * factor) / 2
        let heightInset = (540 - cy * factor) / 2
        let rootLinks = try archive.links(from: "ppt/presentation.xml")
        var draft = Deck(slides: [])
        var imageIDs: [String: UUID] = [:]
        let source = url.lastPathComponent

        for (index, slideID) in slideIDs.enumerated() {
            guard let relation = slideID.attribute(forLocalName: "id", uri: OfficeNamespace.relationships)?.stringValue,
                  let path = rootLinks[relation]?.path else { throw CocoaError(.fileReadCorruptFile) }
            let xml = try archive.xml(path)
            guard let content = xml.child("cSld"), let objects = content.child("spTree") else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let links = try archive.links(from: path, optional: true)
            var context = PowerPointLayout(defaults: root.child("defaultTextStyle"))
            if let path = links.values.first(where: { $0.type == "slideLayout" })?.path {
                context = try archive.layout(at: path, defaults: context.defaults)
            }
            let background = content.child("bg") ?? context.layout?.child("cSld")?.child("bg") ??
                context.master?.child("cSld")?.child("bg")
            let backgroundColor = background?.child("bgPr").flatMap { context.color($0) }
            var slide = Slide(background: backgroundColor ?? "FFFFFF")
            var diagnostics: [ImportDiagnostic] = []
            func note(_ kind: ImportDiagnostic.Kind, _ detail: String, object: UUID? = nil) {
                let diagnostic = ImportDiagnostic(kind: kind, detail: detail, objectID: object)
                if !diagnostics.contains(diagnostic) { diagnostics.append(diagnostic) }
            }
            if abs(cx / cy - 16.0 / 9.0) > 0.002 { note(.canvas, "源页面按比例放入 16∶9 画布。") }
            if background != nil && backgroundColor == nil {
                note(.background, "本页使用了渐变、图片或主题背景，已改用白色。")
            }
            let showMaster = xml.value("showMasterSp") != "0" && context.layout?.value("showMasterSp") != "0"
            let inheritedParts = [context.layout, showMaster ? context.master : nil].compactMap { $0 }
            if inheritedParts.contains(where: { part in
                (part.child("cSld")?.child("spTree")?.elementChildren ?? []).contains {
                    ["sp", "pic", "grpSp", "graphicFrame", "cxnSp"].contains($0.localName ?? "") && $0.placeholder == nil
                }
            }) { note(.unsupported, "版式或母版上的独立装饰对象未转换。") }

            if let notes = links.values.first(where: { $0.type == "notesSlide" }) {
                let notesXML = try archive.xml(notes.path)
                let noteShapes = notesXML.child("cSld")?.child("spTree")?.children(named: "sp") ?? []
                slide.speakerNotes = noteShapes.first(where: { $0.placeholderType == "body" })?
                    .child("txBody")?.plainText ?? ""
            }

            for element in objects.elementChildren {
                let name = element.localName ?? ""
                if name == "nvGrpSpPr" || name == "grpSpPr" { continue }
                let sourceName = element.elementChildren.first { $0.localName?.hasPrefix("nv") == true }?
                    .child("cNvPr")?.value("name")
                let label = String((sourceName?.isEmpty == false ? sourceName ?? name : name).prefix(60))
                guard name == "sp" || name == "pic" else {
                    let type = ["grpSp": "组合对象", "graphicFrame": "表格、图表或 SmartArt", "cxnSp": "连接线"][name] ?? "对象"
                    note(.unsupported, "\(type)「\(label)」未转换。")
                    continue
                }

                let ancestry = context.inheritance(for: element)
                let properties = element.child("spPr")
                let transform = ancestry.lazy.compactMap { $0.child("spPr")?.child("xfrm") }
                    .first { $0.child("off") != nil && $0.child("ext") != nil }
                let origin = transform?.child("off")
                let extent = transform?.child("ext")
                var object = SlideObject()
                let hasGeometry: Bool
                if let x = origin?.number("x"), let y = origin?.number("y"),
                   let width = extent?.number("cx"), let height = extent?.number("cy"),
                   abs(x * factor) <= 9_000, abs(y * factor) <= 9_000,
                   width > 0, width * factor <= 10_000, height > 0, height * factor <= 10_000 {
                    object.x = x * factor + widthInset
                    object.y = y * factor + heightInset
                    object.width = max(1, width * factor)
                    object.height = max(1, height * factor)
                    hasGeometry = true
                } else {
                    object.y = slide.objects.isEmpty ? 72 : min(390, 72 + Double(slide.objects.count) * 112)
                    object.height = slide.objects.isEmpty ? 100 : 140
                    hasGeometry = false
                }
                if (transform?.number("rot") ?? 0) != 0 || transform?.value("flipH") == "1" ||
                    transform?.value("flipV") == "1" {
                    note(.geometry, "「\(label)」的旋转或翻转未保留。", object: object.id)
                }

                if name == "pic" {
                    guard let ref = element.child("blipFill")?.child("blip")?
                        .attribute(forLocalName: "embed", uri: OfficeNamespace.relationships)?.stringValue,
                          let imagePath = links[ref]?.path else {
                        note(.image, "「\(label)」没有可读取的嵌入图片。")
                        continue
                    }
                    if imageIDs[imagePath] == nil {
                        guard let bytes = try archive.part(imagePath, maximum: 48 * 1024 * 1024, optional: true),
                              let png = prepareImage(bytes) else {
                            note(.image, "「\(label)」的图片无法解码。")
                            continue
                        }
                        let id = UUID()
                        imageIDs[imagePath] = id
                        draft.images[id] = png
                    }
                    object.kind = .image
                    object.imageID = imageIDs[imagePath]
                    if !hasGeometry { note(.geometry, "「\(label)」使用了默认位置。", object: object.id) }
                    if let crop = element.child("blipFill")?.child("srcRect"),
                       ["l", "t", "r", "b"].contains(where: { (crop.number($0) ?? 0) != 0 }) {
                        note(.crop, "「\(label)」已显示原图，源文件的裁剪范围未保留。", object: object.id)
                    }
                    slide.objects.append(object)
                    continue
                }

                let textBody = element.child("txBody")
                let text = textBody?.text(softBreak: "\u{2028}") ?? ""
                let fill = properties.flatMap { context.color($0) }
                let preset = properties?.child("prstGeom")?.value("prst")
                guard !text.isEmpty || fill != nil else {
                    if element.placeholder == nil { note(.unsupported, "「\(label)」的形状或效果未转换。") }
                    continue
                }
                if !hasGeometry {
                    note(element.placeholder != nil ? .placeholder : .geometry,
                         "「\(label)」使用了默认位置。", object: object.id)
                }
                if (preset != nil && preset != "rect") || properties?.child("ln")?.child("solidFill") != nil ||
                    properties?.child("gradFill") != nil || properties?.child("custGeom") != nil ||
                    (fill == nil && (element.child("style")?.child("fillRef")?.number("idx") ?? 0) > 0) {
                    note(.geometry, "「\(label)」的形状、边框或填充已简化。", object: object.id)
                }
                if let fill {
                    var background = object
                    if !text.isEmpty { background.id = UUID() }
                    background.kind = .rectangle
                    background.color = fill
                    slide.objects.append(background)
                }
                if let textBody, !text.isEmpty {
                    let imported = ImportedText(body: textBody, shape: element, ancestry: ancestry,
                                                context: context, unit: factor, frame: object.frame)
                    object.text = text
                    let type = ancestry.dropFirst().first?.placeholderType ?? element.placeholderType
                    object.fontSize = imported.size ?? (["title", "ctrTitle"].contains(type ?? "") ? 46 : 30)
                    object.bold = imported.bold
                    object.color = imported.color
                    object.textLayout = imported.layout
                    if let font = imported.layout.fontName, fontAvailable?(font) == false {
                        note(.font, "「\(label)」使用了本机缺少的字体「\(font)」，显示时使用系统替代字体。", object: object.id)
                    }
                    if imported.mixed {
                        note(.text, "「\(label)」的局部字体、字号、颜色或文字效果已统一或简化。", object: object.id)
                    }
                    if imported.approximateParagraph {
                        note(.paragraph, "「\(label)」的特殊段落格式、自动缩放或编号已简化。", object: object.id)
                    }
                    slide.objects.append(object)
                }
            }
            if xml.child("timing") != nil || xml.child("transition") != nil {
                note(.timing, "保留静态页面内容。")
            }
            slide.importReport = SlideImportReport(sourceName: source, sourcePage: index + 1, diagnostics: diagnostics)
            draft.slides.append(slide)
        }
        return ImportedDeck(deck: try draft.validated())
    }
}

private enum OfficeNamespace {
    static let relationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
}

private final class PresentationArchive {
    let url: URL
    private var layouts: [String: PowerPointLayout] = [:]
    private var inheritedParts: [String: XMLElement] = [:]
    private var remaining = 192 * 1024 * 1024

    init(url: URL) { self.url = url }

    func layout(at path: String, defaults: XMLElement?) throws -> PowerPointLayout {
        if let existing = layouts[path] { return existing }
        var result = PowerPointLayout(defaults: defaults)
        result.layout = try inheritedPart(path)
        if let path = try links(from: path, optional: true).values.first(where: { $0.type == "slideMaster" })?.path {
            result.master = try inheritedPart(path)
            if let theme = try links(from: path, optional: true).values.first(where: { $0.type == "theme" })?.path {
                result.theme = try inheritedPart(theme)
            }
        }
        layouts[path] = result
        return result
    }

    private func inheritedPart(_ path: String) throws -> XMLElement {
        if let existing = inheritedParts[path] { return existing }
        let part = try xml(path)
        inheritedParts[path] = part
        return part
    }

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

extension XMLElement {
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
        placeholder.map {
            $0.unqualifiedAttribute("type")?.stringValue ?? "obj"
        }
    }

    var plainText: String { text(softBreak: "\n") }

    func text(softBreak: String) -> String {
        children(named: "p").map { paragraph in
            paragraph.elementChildren.map { item in
                if item.localName == "br" { return softBreak }
                return item.child("t")?.stringValue ?? ""
            }.joined()
        }.joined(separator: "\n")
    }
}
