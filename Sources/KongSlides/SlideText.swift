import AppKit
import CoreText

enum SlideText {
    private static let emphasis = NSAttributedString.Key("KongSlidesHighlight")
    private static let distributed = NSAttributedString.Key("KongSlidesDistributed")

    static func listMarkerInset(_ paragraph: SlideParagraph, scale: CGFloat = 1) -> CGFloat {
        paragraph.firstLine < 0 ? max(0, paragraph.left + paragraph.firstLine) * scale : 0
    }

    private static func listContentInset(_ paragraph: SlideParagraph, fontSize: CGFloat, scale: CGFloat = 1) -> CGFloat {
        let markerLength = CGFloat(paragraph.bullet?.marker.count ?? 0)
        return max(paragraph.left * scale, listMarkerInset(paragraph, scale: scale) + fontSize * max(1.25, markerLength * 0.65))
    }

    static func draw(_ object: SlideObject, in rect: CGRect, context: CGContext) {
        let frame = frame(object, text: attributed(object), in: rect)
        context.saveGState()
        defer { context.restoreGState() }
        let path = CTFrameGetPath(frame)
        context.addPath(path)
        context.clip()
        context.textMatrix = .identity
        let styledRuns = (object.textRuns ?? []).compactMap(\.characterStyle) + [object.characterStyle].compactMap { $0 }
        let needsDecorations = styledRuns.contains { $0.highlight != nil || $0.strikethrough }
        let needsDistribution = object.textLayout?.paragraphs.contains { $0.alignment == .distributed } == true
        guard needsDecorations || needsDistribution, let lines = CTFrameGetLines(frame) as? [CTLine] else {
            CTFrameDraw(frame, context)
            return
        }
        var origins = Array(repeating: CGPoint.zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        let bounds = path.boundingBoxOfPath
        for (original, position) in zip(lines, origins) {
            let origin = CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y)
            let first = (CTLineGetGlyphRuns(original) as? [CTRun])?.first
            let distribute = first.map { (CTRunGetAttributes($0) as NSDictionary)[distributed] as? Bool == true } ?? false
            let line = distribute ? CTLineCreateJustifiedLine(original, 1, bounds.maxX - origin.x) ?? original : original
            let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
            for run in runs { drawDecoration(run, at: origin, context: context, background: true) }
            context.textPosition = origin
            CTLineDraw(line, context)
            for run in runs { drawDecoration(run, at: origin, context: context, background: false) }
        }
    }

    private static func drawDecoration(_ run: CTRun, at origin: CGPoint, context: CGContext, background: Bool) {
        let attributes = CTRunGetAttributes(run) as NSDictionary
        let highlight = attributes[emphasis] as? String
        let strike = attributes[NSAttributedString.Key.strikethroughStyle] as? Int == NSUnderlineStyle.single.rawValue
        guard (background ? highlight != nil : strike), CTRunGetGlyphCount(run) > 0 else { return }
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), &ascent, &descent, nil)
        var position = CGPoint.zero
        CTRunGetPositions(run, CFRange(location: 0, length: 1), &position)
        let x = origin.x + position.x
        let y = origin.y + position.y
        if background, let highlight {
            context.setFillColor(Palette.color(highlight).cgColor)
            context.fill(CGRect(x: x, y: y - descent, width: width, height: ascent + descent))
        } else {
            let color = attributes[NSAttributedString.Key.foregroundColor] as? NSColor
            context.setFillColor((color ?? .labelColor).cgColor)
            context.fill(CGRect(x: x, y: y + ascent * 0.33, width: width, height: max(0.7, ascent * 0.06)))
        }
    }

    private static func frame(_ object: SlideObject, text: NSAttributedString, in rect: CGRect) -> CTFrame {
        let layout = object.textLayout
        let inset = layout?.insets ?? .init()
        let content = CGRect(x: rect.minX + inset.left, y: rect.minY + inset.bottom,
                             width: max(0, rect.width - inset.left - inset.right),
                             height: max(0, rect.height - inset.top - inset.bottom))
        return CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(text as CFAttributedString),
                                         CFRange(location: 0, length: 0),
                                         CGPath(rect: content, transform: nil), nil)
    }

    static func isClipped(_ object: SlideObject) -> Bool {
        let text = attributed(object)
        let content = frame(object, text: text, in: CGRect(origin: .zero, size: object.frame.size))
        let visible = CTFrameGetVisibleStringRange(content)
        if visible.length < text.length {
            let remainder = (text.string as NSString).substring(from: max(0, visible.length))
            if !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        }
        guard let lines = CTFrameGetLines(content) as? [CTLine], !lines.isEmpty else { return false }
        let bounds = CTFrameGetPath(content).boundingBoxOfPath
        var origins = Array(repeating: CGPoint.zero, count: lines.count)
        CTFrameGetLineOrigins(content, CFRange(location: 0, length: 0), &origins)
        return zip(lines, origins).contains { line, origin in
            let box = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds).offsetBy(dx: origin.x, dy: origin.y)
            return !box.isEmpty && (box.minX < -1 || box.maxX > bounds.width + 1 ||
                                   box.minY < -1 || box.maxY > bounds.height + 1)
        }
    }

    private static func attributed(_ object: SlideObject) -> NSAttributedString {
        let size = CGFloat(object.fontSize)
        let objectStyle = object.baseTextStyle

        let result = NSMutableAttributedString(string: "")
        let paragraphs = object.textLayout?.paragraphs ?? []
        let lines = object.text.components(separatedBy: "\n")
        var offset = 0
        for (index, line) in lines.enumerated() {
            let format = paragraphs.indices.contains(index) ? paragraphs[index] : SlideParagraph()
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            switch format.alignment {
            case .left: paragraph.alignment = .left
            case .center: paragraph.alignment = .center
            case .right: paragraph.alignment = .right
            case .justified, .distributed: paragraph.alignment = .justified
            }
            if let multiple = format.lineMultiple { paragraph.lineHeightMultiple = multiple }
            if let height = format.lineHeight {
                paragraph.minimumLineHeight = height
                paragraph.maximumLineHeight = height
            }
            paragraph.paragraphSpacingBefore = format.before
            paragraph.paragraphSpacing = format.after
            paragraph.headIndent = format.left
            paragraph.firstLineHeadIndent = max(0, format.left + format.firstLine)
            let prefix: String
            if let bullet = format.bullet {
                paragraph.headIndent = listContentInset(format, fontSize: size)
                paragraph.firstLineHeadIndent = listMarkerInset(format)
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: paragraph.headIndent)]
                prefix = bullet.marker + "\t"
            } else {
                prefix = ""
            }
            var base = editorAttributes(objectStyle, fallback: object)
            base.removeValue(forKey: .backgroundColor)
            base[.paragraphStyle] = paragraph
            if format.alignment == .distributed { base[distributed] = true }
            result.append(NSAttributedString(string: prefix, attributes: base))
            let end = offset + line.utf16.count
            for (text, run) in object.textSegments(in: offset..<end) {
                var attributes = run.map { editorAttributes($0, fallback: object) } ?? base
                attributes[.paragraphStyle] = paragraph
                if format.alignment == .distributed { attributes[distributed] = true }
                attributes.removeValue(forKey: .backgroundColor)
                if let highlight = (run ?? objectStyle).characterStyle?.highlight { attributes[emphasis] = highlight }
                result.append(NSAttributedString(string: text, attributes: attributes))
            }
            if index + 1 < lines.count {
                result.append(NSAttributedString(string: "\n", attributes: base))
            }
            offset = end + 1
        }
        return result
    }

    static func editorAttributes(_ run: SlideTextRun, fallback object: SlideObject, scale: CGFloat = 1) -> [NSAttributedString.Key: Any] {
        let style = run.characterStyle ?? .init()
        let pointSize = CGFloat(run.size ?? object.fontSize) * scale
        var attributes: [NSAttributedString.Key: Any] = [
            .font: SlideFonts.typeface(run.usesSystemFont == true ? nil : run.fontName ?? object.textLayout?.fontName,
                                      size: pointSize * (run.baseline == 0 ? 1 : 0.72), bold: run.bold, italic: style.italic),
            .foregroundColor: Palette.color(run.color),
            .baselineOffset: pointSize * run.baseline,
            .underlineStyle: style.underline ? NSUnderlineStyle.single.rawValue : 0,
            .strikethroughStyle: style.strikethrough ? NSUnderlineStyle.single.rawValue : 0
        ]
        if style.spacing != 0 { attributes[.kern] = style.spacing * scale }
        if let highlight = style.highlight { attributes[.backgroundColor] = Palette.color(highlight) }
        return attributes
    }

    static func editableText(_ object: SlideObject, scale: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let base = object.baseTextStyle
        for (piece, run) in object.textSegments(in: 0..<object.text.utf16.count) {
            result.append(NSAttributedString(string: piece,
                attributes: editorAttributes(run ?? base, fallback: object, scale: scale)))
        }
        var offset = 0
        let lines = object.text.components(separatedBy: "\n")
        for (index, format) in object.paragraphStyles.enumerated() {
            let count = lines[index].utf16.count + (index + 1 < lines.count ? 1 : 0)
            let range = NSRange(location: offset, length: count)
            offset += count
            let paragraph = NSMutableParagraphStyle()
            switch format.alignment {
            case .left: paragraph.alignment = .left
            case .center: paragraph.alignment = .center
            case .right: paragraph.alignment = .right
            case .justified, .distributed: paragraph.alignment = .justified
            }
            paragraph.lineHeightMultiple = format.lineMultiple ?? 0
            if let height = format.lineHeight {
                paragraph.minimumLineHeight = height * scale
                paragraph.maximumLineHeight = height * scale
            }
            paragraph.paragraphSpacingBefore = format.before * scale
            paragraph.paragraphSpacing = format.after * scale
            paragraph.headIndent = format.left * scale
            paragraph.firstLineHeadIndent = max(0, (format.left + format.firstLine) * scale)
            if format.bullet != nil {
                let inset = listContentInset(format, fontSize: object.fontSize * scale, scale: scale)
                paragraph.headIndent = inset
                paragraph.firstLineHeadIndent = inset
            }
            if count > 0 { result.addAttribute(.paragraphStyle, value: paragraph, range: range) }
        }
        return result
    }
}

extension SlideText {
    static func splitOverflow(_ object: SlideObject, continuationHeight: Double) -> (first: SlideObject, continuations: [SlideObject])? {
        let source = Array(object.text)
        guard source.count > 1, isClipped(object) else { return nil }

        func portion(_ lower: Int, _ upper: Int, template: SlideObject) -> SlideObject {
            var page = template
            let start = String(source.prefix(lower)).utf16.count
            let value = String(source[lower..<upper])
            let end = start + value.utf16.count
            page.text = value
            page.textRuns = object.textRuns?.compactMap { style in
                let low = max(start, style.start)
                let high = min(end, style.end)
                guard low < high else { return nil }
                var run = style
                run.start = low - start
                run.length = high - low
                return run
            }
            if var layout = object.textLayout {
                let firstParagraph = source[..<lower].count(where: { $0 == "\n" })
                layout.paragraphs = Array(layout.paragraphs.dropFirst(firstParagraph).prefix(value.components(separatedBy: "\n").count))
                page.textLayout = layout
            }
            return page
        }

        var result: [SlideObject] = []
        var start = 0
        var template = object
        while start < source.count {
            var low = start + 1
            var high = source.count
            var fit = start
            while low <= high {
                let candidate = (low + high) / 2
                if isClipped(portion(start, candidate, template: template)) { high = candidate - 1 }
                else { fit = candidate; low = candidate + 1 }
            }
            guard fit > start else { return nil }
            if fit < source.count,
               let boundary = source[(start + (fit - start) / 2)..<fit].lastIndex(where: { $0.isWhitespace }),
               boundary > start {
                fit = boundary + 1
            }
            result.append(portion(start, fit, template: template))
            start = fit
            template.id = UUID()
            template.y = 24
            template.height = max(12, continuationHeight)
        }
        guard let first = result.first, result.count > 1 else { return nil }
        return (first, Array(result.dropFirst()))
    }
}
