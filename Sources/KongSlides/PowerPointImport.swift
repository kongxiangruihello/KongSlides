import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

enum PowerPointReadError: LocalizedError {
    case unavailable
    case legacy
    case protected
    case package
    case invalidPart(String)
    case missingPart(String)
    case limit(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "无法读取源文件。若文件位于云盘，请先下载到本机。"
        case .legacy: "这是旧式 .ppt 文件。请在 PowerPoint 中另存为 .pptx。"
        case .protected: "这是受保护或使用旧式容器的文件。请在 PowerPoint 中打开后另存一份无密码的 .pptx。"
        case .package: "这是无效或不完整的 PPTX 文件包。请重新下载，或在 PowerPoint 中另存副本。"
        case .invalidPart(let path): "无法解析 PPTX 部件「\(path)」。"
        case .missingPart(let path): "PPTX 缺少部件「\(path)」。"
        case .limit(let part): "导入「\(part)」时超过了安全读取上限。请将源课件拆成几份后重试。"
        }
    }
}

extension PowerPoint {
    struct ImportedDeck {
        let deck: Deck
    }

    static func read(_ url: URL, fontAvailable: ((String) -> Bool)? = nil,
                     progress: ((Int, Int) -> Void)? = nil,
                     prepareImage: (Data) -> Data?) throws -> ImportedDeck {
        try Task.checkCancellation()
        let archive = try PresentationArchive(url: url)
        let presentationPath = try archive.presentationPath()
        let root = try archive.xml(presentationPath)
        guard let size = root.child("sldSz"),
              let cx = size.number("cx"), let cy = size.number("cy"),
              (1...200_000_000).contains(cx), (1...200_000_000).contains(cy),
              let slideIDs = root.child("sldIdLst")?.children(named: "sldId"), !slideIDs.isEmpty else {
            throw PowerPointReadError.invalidPart(presentationPath)
        }
        guard slideIDs.count <= 500 else { throw PowerPointReadError.limit("幻灯片数量（最多 500 页）") }
        progress?(0, slideIDs.count)
        let factor = min(1 / 12_700.0, 2000 / max(cx, cy))
        let canvas = SlideCanvas(width: cx * factor, height: cy * factor)
        guard canvas.isValid else { throw PowerPointReadError.invalidPart(presentationPath) }
        let rootLinks = try archive.links(from: presentationPath)
        var draft = Deck(slides: [], importedTitle: url.deletingPathExtension().lastPathComponent, canvas: canvas)
        var imageIDs: [String: UUID] = [:]
        let source = url.lastPathComponent

        var readableSlides = 0
        for (index, slideID) in slideIDs.enumerated() {
            try Task.checkCancellation()
            defer { progress?(index + 1, slideIDs.count) }
            var diagnostics: [ImportDiagnostic] = []
            func note(_ kind: ImportDiagnostic.Kind, _ detail: String, object: UUID? = nil) {
                let diagnostic = ImportDiagnostic(kind: kind, detail: detail, objectID: object)
                if !diagnostics.contains(diagnostic) { diagnostics.append(diagnostic) }
            }
            let xml: XMLElement
            let content: XMLElement
            let objects: XMLElement
            let path: String
            do {
                guard let relation = slideID.officeRelationship("id"), let target = rootLinks[relation]?.path else {
                    throw PowerPointReadError.missingPart("第 \(index + 1) 页的幻灯片关系")
                }
                path = target
                xml = try archive.xml(path)
                guard let common = xml.child("cSld"), let tree = common.child("spTree") else {
                    throw PowerPointReadError.invalidPart(path)
                }
                content = common
                objects = tree
            } catch {
                try Task.checkCancellation()
                if slideIDs.count == 1 { throw error }
                let warning = "无法转换源第 \(index + 1) 页：\(error.localizedDescription)"
                note(.unsupported, warning)
                var placeholder = Slide.titleSlide("源第 \(index + 1) 页未转换", subtitle: error.localizedDescription)
                placeholder.hiddenInShow = true
                placeholder.importReport = SlideImportReport(sourceName: source, sourcePage: index + 1, diagnostics: diagnostics)
                draft.slides.append(placeholder)
                continue
            }
            readableSlides += 1
            let links = try archive.recover({ try archive.links(from: path, optional: true) }, fallback: [:]) {
                note(.unsupported, "本页部分资源关系无法读取：\($0.localizedDescription)")
            }
            var context = PowerPointLayout(defaults: root.child("defaultTextStyle"))
            if let path = links.values.first(where: { $0.type == "slideLayout" })?.path {
                context = try archive.recover({ try archive.layout(at: path, defaults: context.defaults) }, fallback: context) {
                    note(.geometry, "版式或主题无法读取：\($0.localizedDescription)")
                }
            }
            let background = content.child("bg") ?? context.layout?.child("cSld")?.child("bg") ??
                context.master?.child("cSld")?.child("bg")
            let backgroundColor = background?.child("bgPr").flatMap { context.color($0) }
            var slide = Slide(background: backgroundColor ?? "FFFFFF")
            if ["0", "false"].contains(xml.value("show") ?? "") { slide.hiddenInShow = true }
            if factor < 1 / 12_700.0 { note(.canvas, "源页面超过尺寸上限，已等比缩小。") }
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
                slide.speakerNotes = try archive.recover({
                    let notesXML = try archive.xml(notes.path)
                    let shapes = notesXML.child("cSld")?.child("spTree")?.children(named: "sp") ?? []
                    return shapes.first(where: { $0.placeholderType == "body" })?.child("txBody")?.plainText ?? ""
                }, fallback: "") { note(.unsupported, "讲稿无法读取：\($0.localizedDescription)") }
            }

            let importedObjects = try PowerPointGroup.objects(in: objects) { note($0, $1) }
            for (element, coordinates) in importedObjects {
                try Task.checkCancellation()
                let name = element.localName ?? ""
                let label = element.powerPointLabel
                let preset = element.child("spPr")?.child("prstGeom")?.value("prst")
                if name == "cxnSp" || (name == "sp" && ["line", "lineInv"].contains(preset ?? "")) {
                    if let imported = ImportedConnector(element, context: context, unit: factor, coordinates: coordinates) {
                        slide.objects.append(imported.object)
                        for warning in imported.warnings {
                            note(.geometry, "连接线「\(label)」\(warning)", object: imported.object.id)
                        }
                    } else {
                        note(.unsupported, "连接线「\(label)」的路径、尺寸或线条样式无法转换。")
                    }
                    continue
                }
                if name == "graphicFrame", let table = element.child("graphic")?.child("graphicData")?.child("tbl") {
                    if let imported = ImportedTable(table, transform: element.child("xfrm"), context: context, unit: factor, coordinates: coordinates) {
                        slide.objects.append(imported.object)
                        for warning in imported.warnings {
                            note(.unsupported, "表格「\(label)」\(warning)", object: imported.object.id)
                        }
                    } else {
                        note(.unsupported, "表格「\(label)」的尺寸或合并结构无法转换。")
                    }
                    continue
                }
                guard name == "sp" || name == "pic" else {
                    let type = ["graphicFrame": "图表或 SmartArt"][name] ?? "对象"
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
                   let frame = coordinates.frame(x: x, y: y, width: width, height: height, unit: factor) {
                    object.x = frame.minX
                    object.y = frame.minY
                    object.width = frame.width
                    object.height = frame.height
                    hasGeometry = true
                } else {
                    object.y = slide.objects.isEmpty ? 72 : min(390, 72 + Double(slide.objects.count) * 112)
                    object.height = slide.objects.isEmpty ? 100 : 140
                    hasGeometry = false
                }
                if name != "pic", transform?.hasPowerPointReorientation == true {
                    note(.geometry, "「\(label)」的旋转或翻转未保留。", object: object.id)
                }

                if name == "pic" {
                    let blip = element.child("blipFill")?.child("blip")
                    guard let ref = blip?.officeRelationship("embed"),
                          let imagePath = links[ref]?.path else {
                        note(.image, "「\(label)」没有可读取的嵌入图片。")
                        continue
                    }
                    if imageIDs[imagePath] == nil {
                        let imageData = try archive.recover({
                            try archive.part(imagePath, maximum: 48 * 1024 * 1024)
                        }, fallback: nil) { note(.image, "图片 \(label) 无法读取：\($0.localizedDescription)") }
                        guard let bytes = imageData,
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
                    let angle = (transform?.number("rot") ?? 0) / 60_000
                    let rawOpacity = blip?.child("alphaModFix")
                    var opacity = 1.0
                    if let amount = rawOpacity?.number("amt") {
                        opacity = min(1, max(0, amount / 100_000))
                    } else if let percent = rawOpacity?.value("amt"), percent.hasSuffix("%"),
                              let amount = Double(percent.dropLast()), amount.isFinite {
                        opacity = min(1, max(0, amount / 100))
                    }
                    let normalizedAngle = (angle + 180).truncatingRemainder(dividingBy: 360)
                    let picture = PictureAppearance(angle: (normalizedAngle + 360).truncatingRemainder(dividingBy: 360) - 180,
                                                    opacity: opacity, flipHorizontal: transform?.powerPointFlag("flipH") == true,
                                                    flipVertical: transform?.powerPointFlag("flipV") == true)
                    if angle.truncatingRemainder(dividingBy: 180) != 0,
                       abs(coordinates.scaleX - coordinates.scaleY) > max(coordinates.scaleX, coordinates.scaleY) * 0.001 {
                        note(.geometry, "「\(label)」在非等比组合中的旋转效果已近似转换。", object: object.id)
                    }
                    if picture != PictureAppearance() { object.pictureAppearance = picture }
                    if blip?.elementChildren.contains(where: { ["alphaBiLevel", "alphaInv", "alphaRepl", "alphaMod"].contains($0.localName ?? "") }) == true {
                        note(.image, "「\(label)」的特殊透明效果已简化。", object: object.id)
                    }
                    if !hasGeometry { note(.geometry, "「\(label)」使用了默认位置。", object: object.id) }
                    if let crop = element.child("blipFill")?.child("srcRect") {
                        func edge(_ name: String) -> Double {
                            if let points = crop.number(name) { return points / 100_000 }
                            let value = crop.value(name) ?? ""
                            if value.isEmpty { return 0 }
                            return value.hasSuffix("%") ? (Double(value.dropLast()) ?? .nan) / 100 : .nan
                        }
                        let area = PictureCrop(left: edge("l"), top: edge("t"), right: edge("r"), bottom: edge("b"))
                        if area.isValid {
                            if area != PictureCrop() { object.pictureCrop = area }
                        } else {
                            note(.crop, "「\(label)」的留白或特殊裁剪未保留，已显示原图。", object: object.id)
                        }
                    }
                    slide.objects.append(object)
                    continue
                }

                let textBody = element.child("txBody")
                let text = textBody?.text(softBreak: "\u{2028}") ?? ""
                let fill = properties.flatMap { context.color($0) }
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
                                                context: context, unit: factor * coordinates.textScale, frame: object.frame)
                    object.text = text
                    let type = ancestry.dropFirst().first?.placeholderType ?? element.placeholderType
                    let defaultSize = ["title", "ctrTitle"].contains(type ?? "") ? 46.0 : 30.0
                    object.fontSize = imported.size ?? min(200, max(8, defaultSize * coordinates.textScale))
                    object.bold = imported.bold
                    object.color = imported.color
                    object.textLayout = imported.layout
                    if let first = imported.runs.first,
                       first.baseline != 0 || imported.runs.contains(where: { !$0.matchesStyle(first) }) {
                        object.textRuns = imported.runs
                    }
                    let fonts = Set(imported.runs.compactMap(\.fontName)).sorted()
                    for font in fonts where fontAvailable?(font) == false {
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
        guard readableSlides > 0 else { throw PowerPointReadError.invalidPart("未找到可读取的幻灯片") }
        return ImportedDeck(deck: try draft.validated())
    }
}

private enum OfficeNamespace {
    static let relationships = [
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships",
        "http://purl.oclc.org/ooxml/officeDocument/relationships"
    ]
}

private final class PresentationArchive {
    let url: URL
    private var layouts: [String: PowerPointLayout] = [:]
    private var inheritedParts: [String: XMLElement] = [:]
    private var remaining = 192 * 1024 * 1024

    init(url: URL) throws {
        self.url = url
        if url.pathExtension.lowercased() == "ppt" { throw PowerPointReadError.legacy }
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw PowerPointReadError.unavailable }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: 8) else { throw PowerPointReadError.unavailable }
        if prefix == Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) {
            throw PowerPointReadError.protected
        }
        guard prefix.starts(with: [0x50, 0x4B, 0x03, 0x04]) else { throw PowerPointReadError.package }
    }

    func presentationPath() throws -> String {
        let entries = try links(from: "")
        guard let path = entries.values.first(where: { $0.type == "officeDocument" })?.path else {
            throw PowerPointReadError.missingPart("根关系中的演示文稿")
        }
        return path
    }

    func recover<T>(_ read: () throws -> T, fallback: T, report: (Error) -> Void) throws -> T {
        do { return try read() }
        catch {
            try Task.checkCancellation()
            report(error)
            return fallback
        }
    }

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
              let root = try xmlDocument(data, path: path).rootElement()?.copy() as? XMLElement else {
            throw PowerPointReadError.invalidPart(path)
        }
        return root
    }

    func links(from part: String, optional: Bool = false) throws -> [String: (type: String, path: String)] {
        let location = part.split(separator: "/").map(String.init)
        let folder = Array(location.dropLast())
        let path = (folder + ["_rels", (location.last ?? "") + ".rels"]).joined(separator: "/")
        guard let data = try self.part(path, maximum: 4 * 1024 * 1024, optional: optional) else { return [:] }
        let document = try xmlDocument(data, path: path)
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
            if valid && !resolved.isEmpty {
                result[id] = (String(type), resolved.joined(separator: "/"))
            }
        }
        return result
    }

    private func xmlDocument(_ data: Data, path: String) throws -> XMLDocument {
        let prefix = Array(data.prefix(4))
        let encoding: String.Encoding
        if prefix.starts(with: [0xFE, 0xFF]) || prefix.starts(with: [0xFF, 0xFE]) {
            encoding = .utf16
        } else if prefix.starts(with: [0x00, 0x3C]) {
            encoding = .utf16BigEndian
        } else if prefix.starts(with: [0x3C, 0x00]) {
            encoding = .utf16LittleEndian
        } else {
            encoding = .utf8
        }
        guard let text = String(data: data, encoding: encoding), !text.contains("\0"),
              !text.contains("<!DOCTYPE") else {
            throw PowerPointReadError.invalidPart(path)
        }
        // The input has already been decoded into Swift text; remove any old byte-encoding declaration.
        var xml = text
        if xml.first == "\u{FEFF}" { xml.removeFirst() }
        if xml.hasPrefix("<?xml "), let end = xml.range(of: "?>") { xml.removeSubrange(..<end.upperBound) }
        do { return try XMLDocument(data: Data(xml.utf8), options: [.nodeLoadExternalEntitiesNever]) }
        catch { throw PowerPointReadError.invalidPart(path) }
    }

    func part(_ path: String, maximum: Int, optional: Bool = false) throws -> Data? {
        try Task.checkCancellation()
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "*?[]\\:#"))
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              !path.unicodeScalars.contains(where: forbidden.contains),
              !path.hasPrefix("-") else {
            throw PowerPointReadError.invalidPart(path)
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
            try Task.checkCancellation()
            guard data.count + chunk.count <= min(maximum, remaining) else {
                throw PowerPointReadError.limit(path)
            }
            data.append(chunk)
        }
        process.waitUntilExit()
        if process.terminationStatus == 11 {
            if optional { return nil }
            throw PowerPointReadError.missingPart(path)
        }
        if [81, 82].contains(process.terminationStatus) { throw PowerPointReadError.protected }
        guard process.terminationStatus == 0 else { throw PowerPointReadError.invalidPart(path) }
        remaining -= data.count
        return data
    }
}

extension XMLElement {
    func officeRelationship(_ localName: String) -> String? {
        OfficeNamespace.relationships.lazy.compactMap {
            self.attribute(forLocalName: localName, uri: $0)?.stringValue
        }.first
    }

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
