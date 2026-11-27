import AppKit
import CoreText

enum SlideText {
    static func frame(_ object: SlideObject, in rect: CGRect) -> CTFrame {
        frame(object, text: attributed(object), in: rect)
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
        let baseFont = SlideFonts.typeface(object.textLayout?.fontName, size: size, bold: object.bold)

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
            case .justified: paragraph.alignment = .justified
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
                paragraph.headIndent = max(format.left, size * 1.25)
                paragraph.firstLineHeadIndent = format.left + format.firstLine < format.left
                    ? max(0, format.left + format.firstLine) : 0
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: paragraph.headIndent)]
                prefix = bullet.marker + "\t"
            } else {
                prefix = ""
            }
            let base: [NSAttributedString.Key: Any] = [.font: baseFont, .foregroundColor: Palette.color(object.color),
                                                        .paragraphStyle: paragraph]
            result.append(NSAttributedString(string: prefix, attributes: base))
            let end = offset + line.utf16.count
            for (text, run) in object.textSegments(in: offset..<end) {
                var attributes = base
                if let run {
                    let pointSize = CGFloat(run.size ?? object.fontSize)
                    attributes[.font] = SlideFonts.typeface(run.fontName ?? object.textLayout?.fontName,
                                             size: pointSize * (run.baseline == 0 ? 1 : 0.72), bold: run.bold)
                    attributes[.foregroundColor] = Palette.color(run.color)
                    attributes[.baselineOffset] = Double(pointSize) * run.baseline
                }
                result.append(NSAttributedString(string: text, attributes: attributes))
            }
            if index + 1 < lines.count {
                result.append(NSAttributedString(string: "\n", attributes: base))
            }
            offset = end + 1
        }
        return result
    }
}
