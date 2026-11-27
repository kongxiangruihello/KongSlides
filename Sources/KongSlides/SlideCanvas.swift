import Foundation

struct SlideCanvas: Codable, Equatable {
    var width: Double
    var height: Double

    static let widescreen = Self(width: 960, height: 540)
    static let standard = Self(width: 720, height: 540)

    var size: CGSize { CGSize(width: width, height: height) }
    var isValid: Bool { (24...2000).contains(width) && (24...2000).contains(height) }

    func fitting(_ object: SlideObject, into target: Self) -> SlideObject {
        guard self != target else { return object }
        let factor = min(target.width / width, target.height / height)
        var result = object
        result.x = (target.width - width * factor) / 2 + object.x * factor
        result.y = (target.height - height * factor) / 2 + object.y * factor
        result.x = min(10_000, max(-10_000, result.x))
        result.y = min(10_000, max(-10_000, result.y))
        result.width = min(10_000, max(1, object.width * factor))
        result.height = min(10_000, max(1, object.height * factor))
        func fontSize(_ size: Double) -> Double { min(200, max(8, size * factor)) }
        result.fontSize = fontSize(object.fontSize)
        result.textRuns = result.textRuns?.map {
            var run = $0
            run.size = run.size.map(fontSize)
            if var style = run.characterStyle {
                style.spacing = min(40, max(-40, style.spacing * factor))
                run.characterStyle = style
            }
            return run
        }
        if var style = result.characterStyle {
            style.spacing = min(40, max(-40, style.spacing * factor))
            result.characterStyle = style
        }
        if var layout = result.textLayout {
            layout.insets.left = min(5000, layout.insets.left * factor)
            layout.insets.right = min(5000, layout.insets.right * factor)
            layout.insets.top = min(5000, layout.insets.top * factor)
            layout.insets.bottom = min(5000, layout.insets.bottom * factor)
            for index in layout.paragraphs.indices {
                layout.paragraphs[index].before = min(1000, layout.paragraphs[index].before * factor)
                layout.paragraphs[index].after = min(1000, layout.paragraphs[index].after * factor)
                layout.paragraphs[index].left = min(10_000, layout.paragraphs[index].left * factor)
                layout.paragraphs[index].firstLine = min(10_000, max(-10_000, layout.paragraphs[index].firstLine * factor))
                layout.paragraphs[index].lineHeight = layout.paragraphs[index].lineHeight.map { min(1000, max(1, $0 * factor)) }
            }
            result.textLayout = layout
        }
        if let weight = result.connector?.weight {
            result.connector?.weight = min(96, max(0.25, weight * factor))
        }
        return result
    }
}

extension Deck {
    var pageCanvas: SlideCanvas { canvas ?? .widescreen }

    func fitted(to target: SlideCanvas) -> Deck {
        guard target.isValid, target != pageCanvas else { return self }
        let current = pageCanvas
        var copy = self
        copy.canvas = target
        for index in copy.slides.indices {
            copy.slides[index].objects = copy.slides[index].objects.map { current.fitting($0, into: target) }
            if let original = copy.slides[index].originalPDFPage {
                copy.slides[index].originalPDFPage = .init(
                    background: original.background, objects: original.objects.map { current.fitting($0, into: target) },
                    previousRepair: original.previousRepair)
            }
        }
        return copy
    }
}
