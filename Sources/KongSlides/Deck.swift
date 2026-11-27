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

struct SlidesDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.kongSlides, .slidePowerPoint]
    static let writableContentTypes: [UTType] = [.kongSlides]
    var deck = Deck()

    init() {}
    init(deck: Deck) { self.deck = deck }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        if configuration.contentType.conforms(to: .slidePowerPoint) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let name = configuration.file.preferredFilename ?? "PowerPoint.pptx"
            let filename = URL(fileURLWithPath: name).lastPathComponent
            let url = directory.appendingPathComponent(filename.isEmpty || [".", ".."].contains(filename) ? "PowerPoint.pptx" : filename)
            try data.write(to: url)
            deck = try PowerPoint.readForEditor(url).deck
        } else {
            deck = try JSONDecoder().decode(Deck.self, from: data).validated()
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard configuration.contentType == .kongSlides else { throw CocoaError(.fileWriteUnsupportedScheme) }
        let data = try JSONEncoder().encode(deck.validated())
        return FileWrapper(regularFileWithContents: data)
    }
}

enum SlideDrawing {
    static func draw(_ slide: Slide, images: [UUID: Data], in context: CGContext, canvas: SlideCanvas = .widescreen) {
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
                guard let id = object.imageID, let data = images[id], let image = picture(data) else { continue }
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
            case .table:
                if let table = object.table { drawTable(table, in: rect, context: context) }
            }
        }
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
