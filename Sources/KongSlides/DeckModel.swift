import Foundation

enum Palette {
    static let ink = "23253A"
    static let paper = "F8F5EE"
    static let indigo = "5045A8"
}

struct SlideObject: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case text, image, rectangle }

    var id = UUID()
    var kind: Kind = .text
    var x: Double = 72
    var y: Double = 84
    var width: Double = 720
    var height: Double = 90
    var text = "输入文字"
    var fontSize: Double = 36
    var bold = false
    var color = Palette.ink
    var imageID: UUID?

    var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    var label: String {
        switch kind {
        case .text: return text.split(separator: "\n").first.map { String($0.prefix(26)) } ?? "文本框"
        case .image: return "图片"
        case .rectangle: return "矩形"
        }
    }
}

struct Slide: Codable, Identifiable, Equatable {
    var id = UUID()
    var section = ""
    var background = Palette.paper
    var speakerNotes = ""
    var objects: [SlideObject] = []

    var title: String {
        let title = objects.lazy.filter { $0.kind == .text }.map(\.label).first
        return title ?? "空白页"
    }

    static func titleSlide(_ title: String, subtitle: String) -> Slide {
        Slide(objects: [
            SlideObject(x: 72, y: 113, width: 812, height: 100, text: title, fontSize: 56, bold: true),
            SlideObject(x: 72, y: 224, width: 812, height: 140, text: subtitle, fontSize: 30),
            SlideObject(kind: .rectangle, x: 72, y: 84, width: 64, height: 6, color: Palette.indigo)
        ])
    }

    static func readingSlide() -> Slide {
        var slide = titleSlide("原文与解读", subtitle: "把课堂投影的原文和要点放在这里。")
        slide.speakerNotes = "在这里添加逐字讲稿、史料出处和课堂提问。"
        return slide
    }
}

struct Deck: Codable, Equatable {
    static let size = CGSize(width: 960, height: 540)
    var schemaVersion = 1
    var slides: [Slide] = [Slide.titleSlide("新建课件", subtitle: "双击文字开始编辑")]
    var images: [UUID: Data] = [:]

    func validated() throws -> Deck {
        guard schemaVersion == 1 else { throw CocoaError(.fileReadUnknown) }
        var result = self
        if result.slides.isEmpty { result.slides = [Slide()] }
        guard Set(result.slides.map(\.id)).count == result.slides.count else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var usedImages: Set<UUID> = []
        for slide in result.slides {
            guard Set(slide.objects.map(\.id)).count == slide.objects.count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            for object in slide.objects {
                guard abs(object.x) <= 10_000, abs(object.y) <= 10_000,
                      (1...10_000).contains(object.width), (1...10_000).contains(object.height),
                      (8...200).contains(object.fontSize) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                if object.kind == .image {
                    guard let id = object.imageID, result.images[id] != nil else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    usedImages.insert(id)
                }
            }
        }
        result.images = result.images.filter { usedImages.contains($0.key) }
        return result
    }
}
