import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

struct PowerPointLayout {
    var layout: XMLElement?
    var master: XMLElement?
    var theme: XMLElement?
    var defaults: XMLElement?
    var layoutPath: String?
    var masterPath: String?

    private func placeholders(in part: XMLElement?) -> [XMLElement] {
        (part?.child("cSld")?.child("spTree")?.elementChildren ?? []).filter { $0.placeholder != nil }
    }

    func inheritance(for shape: XMLElement) -> [XMLElement] {
        guard let placeholder = shape.placeholder else { return [shape] }
        let index = placeholder.value("idx") ?? "0"
        let type = placeholder.value("type")
        let layoutShapes = placeholders(in: layout)
        let layoutShape: XMLElement?
        if shape.placeholderType == "ftr" {
            layoutShape = layoutShapes.first { $0.placeholderType == "ftr" }
        } else {
            layoutShape = layoutShapes.first {
                ($0.placeholder?.value("idx") ?? "0") == index &&
                    (type == nil || $0.placeholderType == type)
            } ?? layoutShapes.first { ($0.placeholder?.value("idx") ?? "0") == index }
        }

        let kind = layoutShape?.placeholderType ?? type ?? "obj"
        let masterShapes = placeholders(in: master)
        let masterKind = kind == "ctrTitle" ? "title" : kind
        let masterShape = masterShapes.first { $0.placeholderType == masterKind } ??
            (["body", "obj", "subTitle"].contains(kind) ? masterShapes.first { $0.placeholderType == "body" } : nil)
        if masterShape === shape { return [shape] }
        return [shape, layoutShape === shape ? nil : layoutShape, masterShape].compactMap { $0 }
    }

    func defaultText(for shape: XMLElement, ancestry: [XMLElement], level: Int) -> [XMLElement] {
        let type = ancestry.dropFirst().first?.placeholderType ?? shape.placeholderType
        let name: String
        switch type {
        case "title", "ctrTitle": name = "titleStyle"
        case "body", "obj", "subTitle": name = "bodyStyle"
        default: name = "otherStyle"
        }
        var styles: [XMLElement] = []
        for (index, element) in ancestry.enumerated() {
            let body = element.child("txBody")
            if index > 0, let direct = body?.children(named: "p").compactMap({ $0.child("pPr") })
                .first(where: { Int($0.number("lvl") ?? 0) == level }) {
                styles.append(direct)
            }
            if let list = body?.child("lstStyle") {
                styles += [list.child("lvl\(level + 1)pPr"), list.child("defPPr")].compactMap { $0 }
            }
        }
        for list in [master?.child("txStyles")?.child(name), defaults].compactMap({ $0 }) {
            styles += [list.child("lvl\(level + 1)pPr"), list.child("defPPr")].compactMap { $0 }
        }
        return styles
    }

    func color(_ element: XMLElement) -> String? {
        if let explicit = element.rgbFill { return explicit }
        return schemeColor(element.child("solidFill")?.child("schemeClr"))
    }

    func schemeColor(_ scheme: XMLElement?) -> String? {
        guard let name = scheme?.value("val") else { return nil }
        let aliases = ["tx1": "dk1", "tx2": "dk2", "bg1": "lt1", "bg2": "lt2"]
        let key = layout?.child("clrMapOvr")?.child("overrideClrMapping")?.value(name) ??
            master?.child("clrMap")?.value(name) ?? aliases[name] ?? name
        let rgb = theme?.child("themeElements")?.child("clrScheme")?.child(key)
        return rgb?.child("srgbClr")?.value("val") ?? rgb?.child("sysClr")?.value("lastClr")
    }

    func font(_ style: [XMLElement], text: String) -> String? {
        let eastAsian = text.unicodeScalars.contains { scalar in
            (0x2E80...0x9FFF).contains(scalar.value) || (0xF900...0xFAFF).contains(scalar.value) ||
                (0x20000...0x323AF).contains(scalar.value)
        }
        let lang = style.lazy.compactMap { $0.value("lang") }.first?.lowercased() ?? ""
        let script = lang.contains("tw") || lang.contains("hk") || lang.contains("hant") ? "Hant" : "Hans"
        let fonts = theme?.child("themeElements")?.child("fontScheme")
        for format in style {
            let candidates = eastAsian ? ["ea", "latin"] : ["latin"]
            for kind in candidates {
                guard let face = format.child(kind)?.value("typeface"), !face.isEmpty else { continue }
                if !face.hasPrefix("+") { return face }
                let group = fonts?.child(face.hasPrefix("+mj") ? "majorFont" : "minorFont")
                if eastAsian || face.hasSuffix("-ea") {
                    if let localized = group?.children(named: "font").first(where: { $0.value("script") == script })?.value("typeface"),
                       !localized.isEmpty { return localized }
                    if let generic = group?.child("ea")?.value("typeface"), !generic.isEmpty { return generic }
                } else if let latin = group?.child("latin")?.value("typeface"), !latin.isEmpty {
                    return latin
                }
            }
        }
        return nil
    }
}

extension XMLElement {
    var placeholder: XMLElement? {
        elementChildren.first { $0.localName?.hasPrefix("nv") == true }?.child("nvPr")?.child("ph")
    }

    func value(_ name: String) -> String? { unqualifiedAttribute(name)?.stringValue }
}

struct ImportedText {
    var layout = SlideTextLayout()
    var size: Double?
    var bold = false
    var color = Palette.ink
    var mixed = false
    var runs: [SlideTextRun] = []
    var approximateParagraph = false

    init(body: XMLElement, shape: XMLElement, ancestry: [XMLElement], context: PowerPointLayout, unit: Double,
         frame: CGRect) {
        let bodies = ancestry.compactMap { $0.child("txBody")?.child("bodyPr") }
        func inset(_ name: String, defaultValue: Double, dimension: Double) -> Double {
            let raw = bodies.lazy.compactMap { $0.number(name) }.first ?? defaultValue
            return min(dimension / 2, max(0, raw * unit))
        }
        layout.insets = .init(left: inset("lIns", defaultValue: 91_440, dimension: frame.width),
                             top: inset("tIns", defaultValue: 45_720, dimension: frame.height),
                             right: inset("rIns", defaultValue: 91_440, dimension: frame.width),
                             bottom: inset("bIns", defaultValue: 45_720, dimension: frame.height))
        approximateParagraph = bodies.contains {
            ["ctr", "b", "just", "dist"].contains($0.value("anchor") ?? "") ||
                ($0.value("vert").map { $0 != "horz" } ?? false) ||
                $0.child("normAutofit") != nil || $0.value("wrap") == "none"
        }
        var numbering: [Int: (number: Int, rule: String)] = [:]
        var hasLeadingStyle = false

        var offset = 0
        for paragraph in body.children(named: "p") {
            let local = paragraph.child("pPr")
            let level = Int(min(8, max(0, local?.number("lvl") ?? 0)))
            var inheritance = context.defaultText(for: shape, ancestry: ancestry, level: level)
            if let local { inheritance.insert(local, at: 0) }
            let defaults = inheritance.compactMap { $0.child("defRPr") }
            for item in paragraph.elementChildren {
                if item.localName == "br" { offset += 1; continue }
                let text = item.child("t")?.stringValue ?? ""
                guard !text.isEmpty else { continue }
                let length = text.utf16.count
                defer { offset += length }
                let applied = [item.child("rPr")].compactMap { $0 } + defaults
                let pointSize = applied.lazy.compactMap { $0.number("sz") }.first.map { min(200, max(8, $0 * 127 * unit)) }
                let weight = ["1", "true"].contains(applied.lazy.compactMap { $0.value("b") }.first ?? "")
                let fill = applied.first { $0.child("solidFill") != nil }
                let rgb = fill.flatMap { context.color($0) } ?? Palette.ink
                let font = context.font(applied, text: text)
                if !hasLeadingStyle {
                    size = pointSize
                    bold = weight
                    color = rgb
                    layout.fontName = font
                    hasLeadingStyle = true
                }
                let baseline = applied.lazy.compactMap { $0.number("baseline") }.first ?? 0
                let color = rgb.utf8.count == 6 && Int(rgb, radix: 16) != nil ? rgb : Palette.ink
                let run = SlideTextRun(start: offset, length: length, size: pointSize, bold: weight,
                                       color: color, fontName: font, baseline: min(1, max(-1, baseline / 100_000)))
                if let last = runs.indices.last, runs[last].end == offset, runs[last].matchesStyle(run) {
                    runs[last].length += length
                } else {
                    runs.append(run)
                }
                if applied.contains(where: { $0.value("i") == "1" || $0.value("u").map { $0 != "none" } == true ||
                    $0.child("hlinkClick") != nil }) {
                    mixed = true
                }
                if let fill, context.color(fill) == nil ||
                    fill.child("solidFill")?.elementChildren.first?.elementChildren.isEmpty == false {
                    mixed = true
                }
            }

            offset += 1
            var format = SlideParagraph()
            switch inheritance.lazy.compactMap({ $0.value("algn") }).first {
            case "ctr": format.alignment = .center
            case "r": format.alignment = .right
            case "just": format.alignment = .justified
            case "dist", "thaiDist", "justLow":
                format.alignment = .justified
                approximateParagraph = true
            default: break
            }
            if let spacing = inheritance.lazy.compactMap({ $0.child("lnSpc") }).first {
                format.lineMultiple = spacing.child("spcPct")?.number("val").map { min(10, max(0.1, $0 / 100_000)) }
                format.lineHeight = spacing.child("spcPts")?.number("val").map { min(1000, max(1, $0 * 127 * unit)) }
            }
            func points(_ name: String) -> Double {
                guard let spacing = inheritance.lazy.compactMap({ $0.child(name) }).first else { return 0 }
                if let pts = spacing.child("spcPts")?.number("val") { return min(1000, max(0, pts * 127 * unit)) }
                if let pct = spacing.child("spcPct")?.number("val") {
                    return min(1000, max(0, (size ?? 30) * pct / 100_000))
                }
                return 0
            }
            format.before = points("spcBef")
            format.after = points("spcAft")
            format.left = min(Double(frame.width), max(0, (inheritance.lazy.compactMap { $0.number("marL") }.first ?? 0) * unit))
            format.firstLine = min(Double(frame.width), max(-Double(frame.width),
                (inheritance.lazy.compactMap { $0.number("indent") }.first ?? 0) * unit))
            if let bullet = inheritance.lazy.compactMap({ style in
                style.elementChildren.first { ["buNone", "buChar", "buAutoNum", "buBlip"].contains($0.localName ?? "") }
            }).first {
                switch bullet.localName {
                case "buChar":
                    format.bullet = .symbol(String((bullet.value("char") ?? "•").prefix(4)))
                    if inheritance.contains(where: { $0.child("buFont")?.value("typeface").map { $0.lowercased().contains("wingdings") } == true }) {
                        format.bullet = .symbol("•")
                        approximateParagraph = true
                    }
                case "buAutoNum":
                    let rule = bullet.value("type") ?? "arabicPeriod"
                    let previous = numbering[level].flatMap { $0.rule == rule ? $0.number : nil }
                    let start = bullet.number("startAt").map { Int(min(32_767, max(1, $0))) }
                    let explicit = local?.child("buAutoNum") != nil ? start : nil
                    let number = explicit ?? previous.map { $0 + 1 } ?? start ?? 1
                    numbering[level] = (number, rule)
                    if !["arabicPeriod", "arabicParenR", "arabicParenBoth"].contains(rule) { approximateParagraph = true }
                    format.bullet = .numbered(number, rule)
                case "buBlip": format.bullet = .symbol("•"); approximateParagraph = true
                default: numbering.removeValue(forKey: level)
                }
            } else {
                numbering.removeValue(forKey: level)
            }
            if inheritance.contains(where: { ($0.number("marR") ?? 0) != 0 || $0.child("tabLst") != nil }) {
                approximateParagraph = true
            }
            layout.paragraphs.append(format)
        }
    }
}
