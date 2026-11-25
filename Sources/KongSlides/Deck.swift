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
    static let kongSlides = UTType(exportedAs: "com.kongslides.deck", conformingTo: .data)
}

struct SlidesDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.kongSlides]
    var deck = Deck()

    init() {}
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        deck = try JSONDecoder().decode(Deck.self, from: data).validated()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = try JSONEncoder().encode(deck.validated())
        return FileWrapper(regularFileWithContents: data)
    }
}

enum SlideDrawing {
    static func draw(_ slide: Slide, images: [UUID: Data], in context: CGContext) {
        // PDF and the SwiftUI canvas both enter here in bottom-left coordinates.
        let height = Deck.size.height
        context.setFillColor(Palette.color(slide.background).cgColor)
        context.fill(CGRect(origin: .zero, size: Deck.size))
        for object in slide.objects {
            let rect = CGRect(x: object.x, y: Double(height) - object.y - object.height,
                              width: object.width, height: object.height)
            switch object.kind {
            case .rectangle:
                context.setFillColor(Palette.color(object.color).cgColor)
                context.fill(rect)
            case .image:
                guard let id = object.imageID, let data = images[id],
                      let provider = CGDataProvider(data: data as CFData),
                      let image = CGImage(pngDataProviderSource: provider, decode: nil,
                                          shouldInterpolate: true, intent: .defaultIntent) else { continue }
                context.draw(image, in: rect)
            case .text:
                let size = CGFloat(object.fontSize)
                let font = object.bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byWordWrapping
                let styled = NSAttributedString(string: object.text, attributes: [
                    .font: font, .foregroundColor: Palette.color(object.color), .paragraphStyle: paragraph
                ])
                let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(styled as CFAttributedString),
                                                      CFRange(location: 0, length: 0),
                                                      CGPath(rect: rect, transform: nil), nil)
                context.saveGState()
                context.clip(to: rect)
                context.textMatrix = .identity
                CTFrameDraw(frame, context)
                context.restoreGState()
            }
        }
    }

    static func pdf(_ deck: Deck, to url: URL) throws {
        guard let buffer = CFDataCreateMutable(nil, 0),
              let consumer = CGDataConsumer(data: buffer) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var page = CGRect(origin: .zero, size: Deck.size)
        guard let context = CGContext(consumer: consumer, mediaBox: &page, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for slide in deck.slides {
            context.beginPDFPage(nil)
            draw(slide, images: deck.images, in: context)
            context.endPDFPage()
        }
        context.closePDF()
        try (buffer as Data).write(to: url, options: .atomic)
    }
}
