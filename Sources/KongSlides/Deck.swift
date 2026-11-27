import AppKit
import CoreText
import SwiftUI
import UniformTypeIdentifiers

extension Palette {
    static func color(_ hex: String) -> NSColor {
        let rgb = Int(hex, radix: 16) ?? 0
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                       green: CGFloat((rgb >> 8) & 255) / 255,
                       blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
}

extension UTType {
    static let slidePowerPoint = UTType(filenameExtension: "pptx") ??
        UTType(importedAs: "org.openxmlformats.presentationml.presentation", conformingTo: .data)
    static let kongSlides = UTType(exportedAs: "com.kongslides.deck", conformingTo: .data)
}

struct SlidesDocument {
    var deck = Deck()

    static func readNative(_ url: URL) throws -> Self {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return Self(deck: try JSONDecoder().decode(Deck.self, from: data).validated())
    }

    func writeNative(to url: URL) throws {
        let data = try JSONEncoder().encode(deck.validated())
        try data.write(to: url, options: .atomic)
    }
}

enum SlideDrawing {
    static func draw(_ slide: Slide, images: [UUID: Data], in context: CGContext, canvas: SlideCanvas = .widescreen,
                     cachedPicture: ((Data, UUID) -> CGImage?)? = nil) {
        // PDF and the SwiftUI canvas both enter here in bottom-left coordinates.
        let height = canvas.height
        context.setFillColor(Palette.color(slide.background).cgColor)
        context.fill(CGRect(origin: .zero, size: canvas.size))
        for object in slide.objects {
            let rect = CGRect(x: object.x, y: Double(height) - object.y - object.height,
                              width: object.width, height: object.height)
            switch object.kind {
            case .rectangle:
                context.setFillColor(Palette.color(object.color).cgColor)
                context.fill(rect)
            case .image:
                guard let id = object.imageID, let data = images[id], let image = cachedPicture?(data, id) ?? picture(data) else { continue }
                context.saveGState()
                if let appearance = object.pictureAppearance {
                    context.setAlpha(appearance.opacity)
                    context.translateBy(x: rect.midX, y: rect.midY)
                    context.rotate(by: -appearance.clockwiseRadians)
                    context.scaleBy(x: appearance.flipHorizontal ? -1 : 1, y: appearance.flipVertical ? -1 : 1)
                    context.translateBy(x: -rect.midX, y: -rect.midY)
                }
                context.clip(to: rect)
                context.draw(image, in: object.pictureCrop?.imageRect(inside: rect) ?? rect)
                context.restoreGState()
            case .text:
                drawText(object, in: rect, context: context)
            case .connector:
                if let line = object.connector { drawConnector(line, object: object, canvasHeight: height, context: context) }
            case .table:
                if let table = object.table { drawTable(table, in: rect, context: context) }
            }
        }
        if let citation = slide.citation, !citation.reference.isEmpty {
            let text = SlideObject(text: String(citation.reference.prefix(130)), fontSize: 12)
            let inset = min(16.0, canvas.width / 8)
            drawText(text, in: CGRect(x: inset, y: 2, width: canvas.width - inset * 2, height: 23), context: context)
        }
    }

    private static func drawConnector(_ line: SlideConnector, object: SlideObject, canvasHeight: CGFloat, context: CGContext) {
        let ends = line.endpoints(in: object.frame)
        let start = CGPoint(x: ends.start.x, y: canvasHeight - ends.start.y)
        let end = CGPoint(x: ends.end.x, y: canvasHeight - ends.end.y)
        let color = Palette.color(object.color).cgColor
        context.saveGState()
        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineWidth(line.weight)
        context.setLineDash(phase: 0, lengths: line.dash.pattern.map { $0 * line.weight })
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
        context.setLineDash(phase: 0, lengths: [])
        drawArrow(line.startArrow, tip: start, toward: end, weight: line.weight, context: context)
        drawArrow(line.endArrow, tip: end, toward: start, weight: line.weight, context: context)
        context.restoreGState()
    }

    private static func drawArrow(_ arrow: SlideConnector.Arrow, tip: CGPoint, toward: CGPoint,
                                  weight: CGFloat, context: CGContext) {
        let distance = hypot(toward.x - tip.x, toward.y - tip.y)
        guard arrow != .none, distance > 0 else { return }
        let length = min(distance / 2, max(6, weight * 3.5))
        let radius = length * 0.46
        context.saveGState()
        context.translateBy(x: tip.x, y: tip.y)
        context.rotate(by: atan2(toward.y - tip.y, toward.x - tip.x))
        if arrow == .oval {
            context.fillEllipse(in: CGRect(x: 0, y: -radius, width: length, height: radius * 2))
        } else {
            let edge = arrow == .diamond ? length / 2 : length
            context.move(to: CGPoint(x: edge, y: radius))
            context.addLine(to: .zero)
            context.addLine(to: CGPoint(x: edge, y: -radius))
            if arrow == .arrow {
                context.setLineJoin(.round)
                context.strokePath()
            } else {
                if arrow == .diamond || arrow == .stealth {
                    context.addLine(to: CGPoint(x: arrow == .diamond ? length : length * 0.72, y: 0))
                }
                context.closePath()
                context.fillPath()
            }
        }
        context.restoreGState()
    }

    private static func drawText(_ object: SlideObject, in rect: CGRect, context: CGContext) {
        let frame = SlideText.frame(object, in: rect)
        context.saveGState()
        context.addPath(CTFrameGetPath(frame))
        context.clip()
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    private static func drawTable(_ table: SlideTable, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.clip(to: rect)
        context.setLineWidth(0.6)
        context.setStrokeColor(Palette.color("D2DAE6").cgColor)
        let columns = SlideTable.edges(table.columns, across: rect.width)
        let rows = SlideTable.edges(table.rows, across: rect.height)
        for cell in table.cells {
            let area = CGRect(x: rect.minX + columns[cell.column], y: rect.maxY - rows[cell.row + cell.rowSpan],
                              width: columns[cell.column + cell.columnSpan] - columns[cell.column],
                              height: rows[cell.row + cell.rowSpan] - rows[cell.row])
            if let color = cell.fill {
                context.setFillColor(Palette.color(color).cgColor)
                context.fill(area)
            }
            context.stroke(area)
            if !cell.text.isEmpty { drawText(cell.textObject, in: area, context: context) }
        }
        context.restoreGState()
    }

    static func picture(_ data: Data) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(pngDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    static func pdf(_ deck: Deck, includeBackups: Bool = true, to url: URL) throws {
        let pages = try deck.pagesForPDF(includeBackups: includeBackups)
        guard let buffer = CFDataCreateMutable(nil, 0),
              let consumer = CGDataConsumer(data: buffer) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var page = CGRect(origin: .zero, size: deck.pageCanvas.size)
        guard let context = CGContext(consumer: consumer, mediaBox: &page, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for (_, slide) in pages {
            context.beginPDFPage(nil)
            draw(slide, images: deck.images, in: context, canvas: deck.pageCanvas)
            context.endPDFPage()
        }
        context.closePDF()
        try (buffer as Data).write(to: url, options: .atomic)
    }
}
