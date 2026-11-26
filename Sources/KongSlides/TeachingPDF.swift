import AppKit
import CoreText

enum TeachingPDF {
    enum Format {
        case teacher
        case studentTwo
        case studentThree

        var label: String {
            switch self {
            case .teacher: "教师讲稿"
            case .studentTwo: "学生配布稿-每页2张"
            case .studentThree: "学生配布稿-每页3张"
            }
        }

        var slidesPerPage: Int { self == .studentTwo ? 2 : 3 }
    }

    private static let paper = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
    private static let margin = 42.0
    private static let bodyColor = NSColor(srgbRed: 0.14, green: 0.17, blue: 0.22, alpha: 1)
    private static let ruleColor = NSColor(srgbRed: 0.79, green: 0.81, blue: 0.85, alpha: 1)

    static func write(_ deck: Deck, format: Format, includeBackups: Bool = false, to url: URL) throws {
        let pages = try deck.pagesForPDF(includeBackups: format == .teacher || includeBackups)
        guard let output = CFDataCreateMutable(nil, 0),
              let consumer = CGDataConsumer(data: output) else { throw CocoaError(.fileWriteUnknown) }
        var page = paper
        guard let context = CGContext(consumer: consumer, mediaBox: &page, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        do {
            switch format {
            case .teacher: try teacher(deck, in: context)
            case .studentTwo, .studentThree: student(pages, images: deck.images, perPage: format.slidesPerPage, in: context)
            }
        } catch {
            context.closePDF()
            throw error
        }
        context.closePDF()
        try (output as Data).write(to: url, options: .atomic)
    }

    private static func teacher(_ deck: Deck, in context: CGContext) throws {
        var pages = 0
        for (index, slide) in deck.slides.enumerated() {
            let notesString = slide.speakerNotes.isEmpty ? "本页暂无讲稿" : slide.speakerNotes
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            paragraph.paragraphSpacing = 5
            let noteText = NSAttributedString(string: notesString, attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: bodyColor, .paragraphStyle: paragraph
            ])
            let typesetter = CTFramesetterCreateWithAttributedString(noteText as CFAttributedString)
            var offset = 0
            repeat {
                let first = offset == 0
                pages += 1
                context.beginPDFPage(nil)
                heading("教师讲稿", detail: "幻灯片 \(index + 1) · \(slide.title)" + (slide.isBackup ? " · 备用页" : "") + (first ? "" : " · 续页"),
                        page: pages, in: context)
                if first {
                    thumbnail(slide, images: deck.images, at: CGPoint(x: margin, y: 554), width: 340, in: context)
                    label("逐字讲稿", at: CGPoint(x: margin, y: 528), fontSize: 13, bold: true, in: context)
                }
                let frame = CGRect(x: margin, y: 52, width: paper.width - 2 * margin, height: first ? 458 : 700)
                let laidOut = CTFramesetterCreateFrame(typesetter, CFRange(location: offset, length: 0),
                                                       CGPath(rect: frame, transform: nil), nil)
                let visible = CTFrameGetVisibleStringRange(laidOut)
                drawNotes(laidOut, inside: frame, in: context)
                context.endPDFPage()
                guard visible.location == offset, visible.length > 0 else { throw CocoaError(.fileWriteUnknown) }
                offset += visible.length
            } while offset < noteText.length
        }
    }

    private static func drawNotes(_ frame: CTFrame, inside bounds: CGRect, in context: CGContext) {
        guard let lines = CTFrameGetLines(frame) as? [CTLine], !lines.isEmpty else { return }
        var positions = Array(repeating: CGPoint.zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &positions)
        context.saveGState()
        context.clip(to: bounds)
        context.textMatrix = .identity
        for (line, position) in zip(lines, positions) {
            context.textPosition = CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y)
            CTLineDraw(line, context)
        }
        context.restoreGState()
    }

    private static func student(_ pages: [(offset: Int, element: Slide)], images: [UUID: Data],
                                perPage: Int, in context: CGContext) {
        let rowHeight = 710.0 / Double(perPage)
        for first in stride(from: 0, to: pages.count, by: perPage) {
            let chunk = pages[first..<min(first + perPage, pages.count)]
            let labels = chunk.map { String($0.offset + 1) }.joined(separator: "、")
            context.beginPDFPage(nil)
            heading("学生配布稿", detail: "幻灯片 \(labels)", page: first / perPage + 1, in: context)
            for (position, page) in chunk.enumerated() {
                let top = 752 - Double(position) * rowHeight
                let width = 309.0
                let bottom = top - 26 - width * Deck.size.height / Deck.size.width
                label("幻灯片 \(page.offset + 1)", at: CGPoint(x: margin, y: top - 14),
                      fontSize: 11, bold: true, in: context)
                thumbnail(page.element, images: images, at: CGPoint(x: margin, y: bottom), width: width, in: context)
                let left = margin + width + 18
                label("课堂笔记", at: CGPoint(x: left, y: top - 14), fontSize: 11, bold: true, in: context)
                for row in 1...7 {
                    let y = top - 28 - Double(row) * 21
                    line(from: CGPoint(x: left, y: y), to: CGPoint(x: paper.width - margin, y: y), in: context)
                }
                let separator = top - rowHeight + 10
                line(from: CGPoint(x: margin, y: separator),
                     to: CGPoint(x: paper.width - margin, y: separator), in: context)
            }
            context.endPDFPage()
        }
    }

    private static func heading(_ title: String, detail: String, page: Int, in context: CGContext) {
        label(title, at: CGPoint(x: margin, y: 801), fontSize: 19, bold: true, in: context)
        label(detail, at: CGPoint(x: margin, y: 776), fontSize: 11, bold: false, in: context)
        line(from: CGPoint(x: margin, y: 764), to: CGPoint(x: paper.width - margin, y: 764), in: context)
        label("KongSlides  ·  \(page)", at: CGPoint(x: margin, y: 30),
              fontSize: 10, bold: false, in: context)
    }

    private static func thumbnail(_ slide: Slide, images: [UUID: Data], at point: CGPoint,
                                  width: CGFloat, in context: CGContext) {
        let scale = width / Deck.size.width
        let frame = CGRect(origin: point, size: CGSize(width: width, height: Deck.size.height * scale))
        context.saveGState()
        context.clip(to: frame)
        context.translateBy(x: point.x, y: point.y)
        context.scaleBy(x: scale, y: scale)
        SlideDrawing.draw(slide, images: images, in: context)
        context.restoreGState()
        context.setStrokeColor(ruleColor.cgColor)
        context.setLineWidth(0.5)
        context.stroke(frame)
    }

    private static func label(_ text: String, at point: CGPoint, fontSize: CGFloat, bold: Bool, in context: CGContext) {
        let font = bold ? NSFont.boldSystemFont(ofSize: fontSize) : NSFont.systemFont(ofSize: fontSize)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: bodyColor
        ]) as CFAttributedString)
        context.textMatrix = .identity
        context.textPosition = point
        CTLineDraw(line, context)
    }

    private static func line(from start: CGPoint, to end: CGPoint, in context: CGContext) {
        context.setStrokeColor(ruleColor.cgColor)
        context.setLineWidth(0.6)
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
    }
}
