import Foundation

enum PowerPoint {
    private static let p = "http://schemas.openxmlformats.org/presentationml/2006/main"
    private static let a = "http://schemas.openxmlformats.org/drawingml/2006/main"
    private static let r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private static let opc = "http://schemas.openxmlformats.org/package/2006"
    private static let contentPrefix = "application/vnd.openxmlformats-officedocument"
    private static let namespace = "xmlns:p=\"\(p)\" xmlns:a=\"\(a)\" xmlns:r=\"\(r)\""
    private static let xmlHeader = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"

    private struct Part {
        let path: String
        let contentType: String?
        let data: Data

        init(_ path: String, _ xml: String, type: String? = nil) {
            self.path = path
            self.contentType = type
            self.data = Data((PowerPoint.xmlHeader + xml).utf8)
        }

        init(_ path: String, bytes: Data) {
            self.path = path
            self.contentType = nil
            self.data = bytes
        }
    }

    static func write(_ deck: Deck, to destination: URL) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let package = directory.appendingPathComponent("package")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for part in try parts(for: deck.validated()) {
            let url = package.appendingPathComponent(part.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try part.data.write(to: url)
        }
        let archive = directory.appendingPathComponent("export.pptx")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = package
        zip.arguments = ["-q", "-r", archive.path, "[Content_Types].xml", "_rels", "ppt"]
        zip.standardOutput = FileHandle.nullDevice
        zip.standardError = FileHandle.nullDevice
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        try Data(contentsOf: archive).write(to: destination, options: .atomic)
    }

    private static func parts(for deck: Deck) -> [Part] {
        let slideIDs = deck.slides.indices.map {
            "<p:sldId id=\"\($0 + 256)\" r:id=\"rId\($0 + 3)\"/>"
        }.joined()
        let presenter = """
        <p:presentation \(namespace)>
        <p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>
        <p:notesMasterIdLst><p:notesMasterId r:id="rId2"/></p:notesMasterIdLst>
        <p:sldIdLst>\(slideIDs)</p:sldIdLst>
        <p:sldSz cx="\(emu(deck.pageCanvas.width))" cy="\(emu(deck.pageCanvas.height))"/>
        <p:notesSz cx="6858000" cy="9144000"/>
        </p:presentation>
        """
        var all: [Part] = [
            Part("_rels/.rels", relations([("officeDocument", "ppt/presentation.xml")])),
            Part("ppt/presentation.xml", presenter, type: "presentation.main"),
            Part("ppt/_rels/presentation.xml.rels", relations([
                ("slideMaster", "slideMasters/slideMaster1.xml"),
                ("notesMaster", "notesMasters/notesMaster1.xml")
            ] + deck.slides.indices.map { ("slide", "slides/slide\($0 + 1).xml") })),
            Part("ppt/slideMasters/slideMaster1.xml", master, type: "slideMaster"),
            Part("ppt/slideMasters/_rels/slideMaster1.xml.rels",
                 relations([("slideLayout", "../slideLayouts/slideLayout1.xml"), ("theme", "../theme/theme1.xml")])),
            Part("ppt/slideLayouts/slideLayout1.xml", layout, type: "slideLayout"),
            Part("ppt/slideLayouts/_rels/slideLayout1.xml.rels",
                 relations([("slideMaster", "../slideMasters/slideMaster1.xml")])),
            Part("ppt/notesMasters/notesMaster1.xml", notesMaster, type: "notesMaster"),
            Part("ppt/notesMasters/_rels/notesMaster1.xml.rels", relations([("theme", "../theme/theme1.xml")])),
            Part("ppt/theme/theme1.xml", theme, type: "theme")
        ]
        for (index, sourceSlide) in deck.slides.enumerated() {
            var slide = sourceSlide
            slide.resolveConnectorAttachments()
            let number = index + 1
            var links = [("slideLayout", "../slideLayouts/slideLayout1.xml")]
            if !slide.speakerNotes.isEmpty {
                links.append(("notesSlide", "../notesSlides/notesSlide\(number).xml"))
                all.append(Part("ppt/notesSlides/notesSlide\(number).xml", notes(slide.speakerNotes), type: "notesSlide"))
                all.append(Part("ppt/notesSlides/_rels/notesSlide\(number).xml.rels",
                                relations([("notesMaster", "../notesMasters/notesMaster1.xml"),
                                           ("slide", "../slides/slide\(number).xml")])))
            }
            var shapes = ""
            var group: UUID?
            var members = ""
            var groupBounds: CGRect?
            var groupNumber = slide.objects.count + 2
            let shapeIDs = Dictionary(uniqueKeysWithValues: slide.objects.enumerated().map { ($0.element.id, $0.offset + 2) })
            func flushGroup() {
                if let bounds = groupBounds, group != nil, !members.isEmpty {
                    let x = emu(bounds.minX), y = emu(bounds.minY)
                    let width = emu(bounds.width), height = emu(bounds.height)
                    shapes += """
                    <p:grpSp><p:nvGrpSpPr><p:cNvPr id="\(groupNumber)" name="Group \(groupNumber)"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
                    <p:grpSpPr><a:xfrm><a:off x="\(x)" y="\(y)"/><a:ext cx="\(width)" cy="\(height)"/>
                    <a:chOff x="\(x)" y="\(y)"/><a:chExt cx="\(width)" cy="\(height)"/></a:xfrm></p:grpSpPr>
                    \(members)</p:grpSp>
                    """
                    groupNumber += 1
                } else {
                    shapes += members
                }
                members = ""
                groupBounds = nil
            }
            for (index, object) in slide.objects.enumerated() {
                if group != object.groupID {
                    flushGroup()
                    group = object.groupID
                }
                if group != nil { groupBounds = groupBounds?.union(object.frame) ?? object.frame }
                let id = index + 2
                switch object.kind {
                case .text:
                    members += textBox(object, id: id)
                case .rectangle:
                    members += rectangle(object, id: id)
                case .connector:
                    if let line = object.connector { members += connectorXML(line, object: object, id: id, shapeIDs: shapeIDs) }
                case .table:
                    if let table = object.table { members += tableXML(table, object: object, id: id) }
                case .image:
                    if let imageID = object.imageID {
                        links.append(("image", "../media/\(imageID.uuidString).png"))
                        members += picture(object, id: id, relationship: links.count)
                    }
                }
            }
            flushGroup()
            let visibility = slide.isBackup ? " show=\"0\"" : ""
            let slideXML = """
            <p:sld \(namespace)\(visibility)><p:cSld>
            <p:bg><p:bgPr>\(fill(slide.background))<a:effectLst/></p:bgPr></p:bg>
            \(shapeTree(shapes))
            </p:cSld>\(overrides)</p:sld>
            """
            all.append(Part("ppt/slides/slide\(number).xml", slideXML, type: "slide"))
            all.append(Part("ppt/slides/_rels/slide\(number).xml.rels", relations(links)))
        }
        for (id, bytes) in deck.images {
            all.append(Part("ppt/media/\(id.uuidString).png", bytes: bytes))
        }

        let types = all.compactMap { part -> String? in
            guard let type = part.contentType else { return nil }
            let mime = type == "theme" ? "\(contentPrefix).theme+xml" : "\(contentPrefix).presentationml.\(type)+xml"
            return "<Override PartName=\"/\(part.path)\" ContentType=\"\(mime)\"/>"
        }.joined()
        all.append(Part("[Content_Types].xml", """
        <Types xmlns="\(opc)/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Default Extension="png" ContentType="image/png"/>
        \(types)</Types>
        """))
        return all
    }

    private static func relations(_ links: [(String, String)]) -> String {
        let entries = links.enumerated().map { i, link in
            "<Relationship Id=\"rId\(i + 1)\" Type=\"\(r)/\(link.0)\" Target=\"\(link.1)\"/>"
        }.joined()
        return "<Relationships xmlns=\"\(opc)/relationships\">\(entries)</Relationships>"
    }

    private static func shapeTree(_ shapes: String) -> String {
        """
        <p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
        <p:grpSpPr/>\(shapes)</p:spTree>
        """
    }

    private static func geometry(_ object: SlideObject) -> String {
        var transform = ""
        if let picture = object.pictureAppearance, object.kind == .image {
            if picture.angle != 0 {
                let angle = (Int((picture.angle * 60_000).rounded()) % 21_600_000 + 21_600_000) % 21_600_000
                transform += " rot=\"\(angle)\""
            }
            if picture.flipHorizontal { transform += " flipH=\"1\"" }
            if picture.flipVertical { transform += " flipV=\"1\"" }
        }
        return """
        <a:xfrm\(transform)><a:off x="\(emu(object.x))" y="\(emu(object.y))"/>
        <a:ext cx="\(emu(object.width))" cy="\(emu(object.height))"/></a:xfrm>
        <a:prstGeom prst="rect"><a:avLst/></a:prstGeom>
        """
    }

    private static func textBox(_ object: SlideObject, id: Int) -> String {
        let margin = object.textLayout?.insets ?? .init()
        return """
        <p:sp><p:nvSpPr><p:cNvPr id="\(id)" name="Text \(id)"/>
        <p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>
        <p:spPr>\(geometry(object))<a:noFill/><a:ln><a:noFill/></a:ln></p:spPr>
        <p:txBody><a:bodyPr lIns="\(emu(margin.left))" tIns="\(emu(margin.top))" rIns="\(emu(margin.right))" bIns="\(emu(margin.bottom))" wrap="square" anchor="t"><a:noAutofit/></a:bodyPr>
        <a:lstStyle/>\(paragraphs(object.text, fontSize: object.fontSize, bold: object.bold, color: object.color, layout: object.textLayout, object: object))
        </p:txBody></p:sp>
        """
    }

    private static func rectangle(_ object: SlideObject, id: Int) -> String {
        """
        <p:sp><p:nvSpPr><p:cNvPr id="\(id)" name="Rectangle \(id)"/>
        <p:cNvSpPr/><p:nvPr/></p:nvSpPr>
        <p:spPr>\(geometry(object))\(fill(object.color))<a:ln><a:noFill/></a:ln></p:spPr></p:sp>
        """
    }

    private static func connectorXML(_ line: SlideConnector, object: SlideObject, id: Int, shapeIDs: [UUID: Int]) -> String {
        let (start, end) = line.endpoints(in: object.frame)
        let startX = emu(start.x), startY = emu(start.y)
        var endX = emu(end.x)
        let endY = emu(end.y)
        // Keep a nonzero extent when a valid, very short line rounds to a point in DrawingML.
        if startX == endX && startY == endY { endX += 1 }
        let flipH = startX > endX ? " flipH=\"1\"" : ""
        let flipV = startY > endY ? " flipV=\"1\"" : ""
        func connection(_ attachment: SlideConnector.Attachment?, tag: String) -> String {
            guard let attachment, let target = shapeIDs[attachment.objectID] else { return "" }
            return "<a:\(tag) id=\"\(target)\" idx=\"\(attachment.edge.rawValue)\"/>"
        }
        let links = connection(line.startAttachment, tag: "stCxn") + connection(line.endAttachment, tag: "endCxn")
        return """
        <p:cxnSp><p:nvCxnSpPr><p:cNvPr id="\(id)" name="Connector \(id)"/><p:cNvCxnSpPr>\(links)</p:cNvCxnSpPr><p:nvPr/></p:nvCxnSpPr>
        <p:spPr><a:xfrm\(flipH)\(flipV)><a:off x="\(min(startX, endX))" y="\(min(startY, endY))"/>
        <a:ext cx="\(abs(endX - startX))" cy="\(abs(endY - startY))"/></a:xfrm>
        <a:prstGeom prst="straightConnector1"><a:avLst/></a:prstGeom>
        <a:ln w="\(emu(line.weight))">\(fill(object.color))<a:prstDash val="\(line.dash.rawValue)"/>
        <a:headEnd type="\(line.startArrow.rawValue)"/><a:tailEnd type="\(line.endArrow.rawValue)"/></a:ln></p:spPr></p:cxnSp>
        """
    }

    private static func tableXML(_ table: SlideTable, object: SlideObject, id: Int) -> String {
        guard let owners = table.occupancy else { return "" }
        let columns = SlideTable.edges(table.columns, across: object.width)
        let rows = SlideTable.edges(table.rows, across: object.height)
        let grid = table.columns.indices.map { column in
            "<a:gridCol w=\"\(max(1, emu(columns[column + 1]) - emu(columns[column])))\"/>"
        }.joined()
        let body = table.rows.indices.map { row in
            let cells = table.columns.indices.map { column in
                let cell = table.cells[owners[row * table.columns.count + column]]
                let horizontal = column != cell.column
                let vertical = row != cell.row
                var attributes = ""
                if !horizontal && cell.columnSpan > 1 { attributes += " gridSpan=\"\(cell.columnSpan)\"" }
                if !vertical && cell.rowSpan > 1 { attributes += " rowSpan=\"\(cell.rowSpan)\"" }
                if horizontal { attributes += " hMerge=\"1\"" }
                if vertical { attributes += " vMerge=\"1\"" }
                if horizontal || vertical {
                    return "<a:tc\(attributes)><a:txBody><a:bodyPr/><a:lstStyle/><a:p/></a:txBody><a:tcPr/></a:tc>"
                }
                let inset = cell.layout?.insets ?? .init()
                let lines = ["lnL", "lnR", "lnT", "lnB"].map { name in
                    "<a:\(name) w=\"7620\">\(fill("D2DAE6"))</a:\(name)>"
                }.joined()
                return """
                <a:tc\(attributes)><a:txBody><a:bodyPr/><a:lstStyle/>
                \(paragraphs(cell.text, fontSize: cell.fontSize, bold: cell.bold, color: cell.color,
                             layout: cell.layout, object: cell.textObject))</a:txBody>
                <a:tcPr marL="\(emu(inset.left))" marR="\(emu(inset.right))" marT="\(emu(inset.top))" marB="\(emu(inset.bottom))">
                \(lines)\(cell.fill.map(fill) ?? "<a:noFill/>")</a:tcPr></a:tc>
                """
            }.joined()
            return "<a:tr h=\"\(max(1, emu(rows[row + 1]) - emu(rows[row])))\">\(cells)</a:tr>"
        }.joined()
        return """
        <p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="\(id)" name="Table \(id)"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr>
        <p:xfrm><a:off x="\(emu(object.x))" y="\(emu(object.y))"/>
        <a:ext cx="\(emu(object.width))" cy="\(emu(object.height))"/></p:xfrm>
        <a:graphic><a:graphicData uri="\(a)/table"><a:tbl><a:tblPr/><a:tblGrid>\(grid)</a:tblGrid>\(body)</a:tbl></a:graphicData></a:graphic>
        </p:graphicFrame>
        """
    }

    private static func picture(_ object: SlideObject, id: Int, relationship: Int) -> String {
        let crop: String
        if let area = object.pictureCrop, area.isValid {
            func percent(_ value: Double) -> Int { Int((value * 100_000).rounded()) }
            crop = """
            <a:srcRect l="\(percent(area.left))" t="\(percent(area.top))" r="\(percent(area.right))" b="\(percent(area.bottom))"/>
            """
        } else {
            crop = ""
        }
        let opacity = object.pictureAppearance?.opacity ?? 1
        let effect = opacity < 1 ? "<a:alphaModFix amt=\"\(Int((opacity * 100_000).rounded()))\"/>" : ""
        return """
        <p:pic><p:nvPicPr><p:cNvPr id="\(id)" name="Image \(id)"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr>
        <p:blipFill><a:blip r:embed="rId\(relationship)">\(effect)</a:blip>\(crop)<a:stretch><a:fillRect/></a:stretch></p:blipFill>
        <p:spPr>\(geometry(object))</p:spPr></p:pic>
        """
    }

    private static func paragraphs(_ text: String, fontSize: Double, bold: Bool = false,
                                   color: String = Palette.ink, layout: SlideTextLayout? = nil,
                                   object: SlideObject? = nil) -> String {
        let normal = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var rich = object
        if normal != text { rich?.replaceText(with: normal) }
        var offset = 0
        func xmlRun(_ text: String, _ style: SlideTextRun?) -> String {
            let size = Int(((style?.size ?? fontSize) * 100).rounded())
            let font = style?.fontName ?? layout?.fontName
            let latin = attribute(font ?? "Arial")
            let eastAsian = attribute(font ?? "+mn-ea")
            let baseline = Int(((style?.baseline ?? 0) * 100_000).rounded())
            let bold = (style?.bold ?? bold) ? 1 : 0
            return """
            <a:r><a:rPr lang="zh-CN" sz="\(size)" b="\(bold)" baseline="\(baseline)">
            \(fill(style?.color ?? color))<a:latin typeface="\(latin)"/><a:ea typeface="\(eastAsian)"/>
            </a:rPr><a:t>\(escaped(text))</a:t></a:r>
            """
        }
        return normal.components(separatedBy: "\n").enumerated().map { index, line in
            let format = layout?.paragraphs.indices.contains(index) == true
                ? layout?.paragraphs[index] ?? SlideParagraph() : SlideParagraph()
            let paragraph = paragraphXML(format)
            let start = offset
            offset += line.utf16.count + 1
            if line.isEmpty {
                let size = Int((fontSize * 100).rounded())
                return "<a:p>\(paragraph)<a:endParaRPr lang=\"zh-CN\" sz=\"\(size)\"/></a:p>"
            }
            let parts = rich?.textSegments(in: start..<(offset - 1)) ?? [(line, nil)]
            let runs = parts.map { content, style in
                content.components(separatedBy: "\u{2028}").map { $0.isEmpty ? "" : xmlRun($0, style) }
                    .joined(separator: "<a:br/>")
            }.joined()
            return "<a:p>\(paragraph)\(runs)</a:p>"
        }.joined()
    }

    private static func paragraphXML(_ format: SlideParagraph) -> String {
        if format == SlideParagraph() { return "<a:pPr marL=\"0\" indent=\"0\"/>" }
        let alignment: String
        switch format.alignment {
        case .left: alignment = "l"
        case .center: alignment = "ctr"
        case .right: alignment = "r"
        case .justified: alignment = "just"
        }
        var children = ""
        if let multiple = format.lineMultiple {
            children += "<a:lnSpc><a:spcPct val=\"\(Int((multiple * 100_000).rounded()))\"/></a:lnSpc>"
        } else if let height = format.lineHeight {
            children += "<a:lnSpc><a:spcPts val=\"\(Int((height * 100).rounded()))\"/></a:lnSpc>"
        }
        if format.before > 0 { children += "<a:spcBef><a:spcPts val=\"\(Int((format.before * 100).rounded()))\"/></a:spcBef>" }
        if format.after > 0 { children += "<a:spcAft><a:spcPts val=\"\(Int((format.after * 100).rounded()))\"/></a:spcAft>" }
        switch format.bullet {
        case .symbol(let sign):
            children += "<a:buChar char=\"\(attribute(sign))\"/>"
        case .numbered(let number, let rule):
            let supported = ["arabicPeriod", "arabicParenR", "arabicParenBoth"]
            let kind = supported.contains(rule) ? rule : "arabicPeriod"
            children += "<a:buAutoNum type=\"\(kind)\" startAt=\"\(min(32_767, max(1, number)))\"/>"
        case nil:
            children += "<a:buNone/>"
        }
        return "<a:pPr marL=\"\(emu(format.left))\" indent=\"\(emu(format.firstLine))\" algn=\"\(alignment)\">\(children)</a:pPr>"
    }

    private static func attribute(_ text: String) -> String {
        escaped(text).replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func escaped(_ text: String) -> String {
        let clean = String(text.unicodeScalars.filter {
            $0.value == 9 || (0x20...0xD7FF).contains($0.value) ||
                (0xE000...0xFFFD).contains($0.value) || (0x10000...0x10FFFF).contains($0.value)
        })
        return clean.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func fill(_ hex: String) -> String {
        let rgb = hex.count == 6 && Int(hex, radix: 16) != nil ? hex : Palette.ink
        return "<a:solidFill><a:srgbClr val=\"\(rgb)\"/></a:solidFill>"
    }

    private static func emu(_ points: Double) -> Int { Int((points * 12_700).rounded()) }

    private static let overrides = "<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>"
    private static let mapping = """
    <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2"
    accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>
    """

    private static var master: String {
        """
        <p:sldMaster \(namespace)><p:cSld>\(shapeTree(""))</p:cSld>\(mapping)
        <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>
        <p:txStyles><p:titleStyle/><p:bodyStyle/><p:otherStyle/></p:txStyles></p:sldMaster>
        """
    }

    private static var layout: String {
        """
        <p:sldLayout \(namespace) type="blank" preserve="1">
        <p:cSld name="Blank">\(shapeTree(""))</p:cSld>\(overrides)</p:sldLayout>
        """
    }

    private static func notes(_ text: String) -> String {
        "<p:notes \(namespace)><p:cSld>\(shapeTree(notesPlaceholder(text)))</p:cSld>\(overrides)</p:notes>"
    }

    private static var notesMaster: String {
        """
        <p:notesMaster \(namespace)><p:cSld>\(shapeTree(notesPlaceholder("", master: true)))</p:cSld>
        \(mapping)<p:notesStyle/></p:notesMaster>
        """
    }

    private static func notesPlaceholder(_ text: String, master: Bool = false) -> String {
        let rect = SlideObject(x: 45, y: 365, width: 450, height: 290)
        return """
        <p:sp><p:nvSpPr><p:cNvPr id="2" name="Notes"/><p:cNvSpPr/><p:nvPr>
        <p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr>
        <p:spPr>\(master ? geometry(rect) : "")</p:spPr>
        <p:txBody><a:bodyPr/><a:lstStyle/>\(paragraphs(text, fontSize: 12))</p:txBody>
        </p:sp>
        """
    }

    private static var theme: String {
        let colors = [("dk1", "23253A"), ("lt1", "FFFFFF"), ("dk2", "343751"), ("lt2", "F8F5EE"),
                      ("accent1", "5045A8"), ("accent2", "A34E42"), ("accent3", "286B61"),
                      ("accent4", "825C27"), ("accent5", "4C739A"), ("accent6", "77618C"),
                      ("hlink", "245E9A"), ("folHlink", "674F88")]
        let scheme = colors.map { "<a:\($0.0)><a:srgbClr val=\"\($0.1)\"/></a:\($0.0)>" }.joined()
        let fonts = "<a:latin typeface=\"Arial\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/><a:font script=\"Hans\" typeface=\"Microsoft YaHei\"/>"
        let fillStyle = "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>"
        let effects = String(repeating: "<a:effectStyle><a:effectLst/></a:effectStyle>", count: 3)
        let lines = [9525, 19050, 28575].map { "<a:ln w=\"\($0)\">\(fillStyle)</a:ln>" }.joined()
        let fills = String(repeating: fillStyle, count: 3)
        return """
        <a:theme xmlns:a="\(a)" name="KongSlides"><a:themeElements><a:clrScheme name="KongSlides">\(scheme)</a:clrScheme>
        <a:fontScheme name="KongSlides"><a:majorFont>\(fonts)</a:majorFont><a:minorFont>\(fonts)</a:minorFont></a:fontScheme>
        <a:fmtScheme name="KongSlides"><a:fillStyleLst>\(fills)</a:fillStyleLst><a:lnStyleLst>\(lines)</a:lnStyleLst>
        <a:effectStyleLst>\(effects)</a:effectStyleLst><a:bgFillStyleLst>\(fills)</a:bgFillStyleLst></a:fmtScheme>
        </a:themeElements></a:theme>
        """
    }
}
