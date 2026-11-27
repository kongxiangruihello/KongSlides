import Foundation

enum Palette {
    static let ink = "23253A"
    static let paper = "F8F5EE"
    static let indigo = "5045A8"
}

struct SlideTextLayout: Codable, Equatable {
    struct Insets: Codable, Equatable {
        var left = 0.0
        var top = 0.0
        var right = 0.0
        var bottom = 0.0
    }

    var fontName: String?
    var insets = Insets()
    var paragraphs: [SlideParagraph] = []

    var isValid: Bool {
        let edges = [insets.left, insets.top, insets.right, insets.bottom]
        return edges.allSatisfy { (0...5000).contains($0) } && paragraphs.allSatisfy {
            (0...1000).contains($0.before) && (0...1000).contains($0.after) &&
                (0...10_000).contains($0.left) && (-10_000...10_000).contains($0.firstLine) &&
                ($0.lineMultiple.map { (0.1...10).contains($0) } ?? true) &&
                ($0.lineHeight.map { (1...1000).contains($0) } ?? true)
        }
    }
}

struct SlideParagraph: Codable, Equatable {
    enum Alignment: String, Codable, CaseIterable { case left, center, right, justified, distributed }

    enum Bullet: Codable, Equatable {
        case symbol(String)
        case numbered(Int, String)

        var marker: String {
            switch self {
            case .symbol(let sign): return sign
            case .numbered(let number, "arabicParenR"): return "\(number))"
            case .numbered(let number, "arabicParenBoth"): return "(\(number))"
            case .numbered(let number, _): return "\(number)."
            }
        }
    }

    var alignment: Alignment = .left
    var lineMultiple: Double?
    var lineHeight: Double?
    var before = 0.0
    var after = 0.0
    var left = 0.0
    var firstLine = 0.0
    var bullet: Bullet?

    func hasList(numbered: Bool) -> Bool {
        switch bullet {
        case .numbered: return numbered
        case .symbol: return !numbered
        case nil: return false
        }
    }

    @discardableResult
    static func renumberList(around index: Int, in formats: inout [Self]) -> Int {
        guard formats.indices.contains(index), case let .numbered(_, rule) = formats[index].bullet else { return index + 1 }
        let indent = formats[index].left
        func matches(_ candidate: Int) -> Bool {
            guard formats.indices.contains(candidate), formats[candidate].left == indent,
                  case let .numbered(_, candidateRule) = formats[candidate].bullet else { return false }
            return candidateRule == rule
        }
        var first = index
        while matches(first - 1) { first -= 1 }
        guard case let .numbered(start, _) = formats[first].bullet else { return index + 1 }
        var current = first
        while matches(current) {
            formats[current].bullet = .numbered(min(32_767, max(1, min(start, 32_767)) + current - first), rule)
            current += 1
        }
        return current
    }
}

struct ImportDiagnostic: Codable, Equatable {
    enum Kind: String, Codable {
        case canvas, background, placeholder, font, text, paragraph, geometry, image, crop, unsupported, timing

        var title: String {
            switch self {
            case .canvas: "页面比例调整"
            case .background: "背景近似"
            case .placeholder: "占位框位置近似"
            case .font: "字体替换"
            case .text: "混合文字样式简化"
            case .paragraph: "段落格式近似"
            case .geometry: "对象样式近似"
            case .image: "图片未导入"
            case .crop: "图片裁剪近似"
            case .unsupported: "对象未转换"
            case .timing: "动画或转场未转换"
            }
        }
    }

    enum Impact: String, Codable, CaseIterable, Identifiable {
        case pageUnavailable, contentMissing, appearance

        var id: Self { self }

        var title: String {
            switch self {
            case .pageUnavailable: "页面未读出"
            case .contentMissing: "内容未转换"
            case .appearance: "样式或效果差异"
            }
        }
    }

    let kind: Kind
    let detail: String
    let objectID: UUID?
    var recordedImpact: Impact? = nil

    var impact: Impact {
        if let recordedImpact { return recordedImpact }
        switch kind {
        case .unsupported where detail.hasPrefix("无法转换源"):
            return .pageUnavailable
        case .unsupported, .image:
            // Previous releases attached the object ID when its content did import.
            return objectID == nil ? .contentMissing : .appearance
        default:
            return .appearance
        }
    }

    var title: String {
        switch (impact, kind) {
        case (.pageUnavailable, _): return "整页读取失败"
        case (.appearance, .unsupported): return "部分格式已简化"
        case (.appearance, .image): return "图片效果近似"
        default: return kind.title
        }
    }
}

struct SlideImportReport: Codable, Equatable {
    struct Repair: Codable, Equatable {
        let pdfName: String
        let pdfPage: Int
    }

    let sourceName: String
    let sourcePage: Int
    let diagnostics: [ImportDiagnostic]
    var repair: Repair? = nil
}

struct SlideObject: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case text, image, rectangle, table, connector }

    enum DecorationSource: String, Codable {
        case master, layout
        var title: String { self == .master ? "PPTX 母版" : "PPTX 版式" }
    }

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
    var textLayout: SlideTextLayout?
    var textRuns: [SlideTextRun]?
    var characterStyle: SlideCharacterStyle?
    var pictureCrop: PictureCrop?
    var pictureAppearance: PictureAppearance?
    var table: SlideTable?
    var connector: SlideConnector?
    var decorationSource: DecorationSource?
    var locked: Bool?
    var groupID: UUID?

    var isLocked: Bool { locked == true }

    var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    mutating func replaceText(with value: String) {
        remapTextRuns(to: value)
        defer { text = value }
        guard var layout = textLayout, !layout.paragraphs.isEmpty else { return }
        let old = text.components(separatedBy: "\n")
        let new = value.components(separatedBy: "\n")
        guard old.count != new.count else { return }

        let prefix = zip(old, new).prefix(while: { pair in pair.0 == pair.1 }).count
        let suffixLimit = min(old.count, new.count) - prefix
        let suffix = zip(old.reversed(), new.reversed()).prefix(suffixLimit).prefix(while: { pair in pair.0 == pair.1 }).count
        func style(at index: Int) -> SlideParagraph {
            layout.paragraphs.indices.contains(index) ? layout.paragraphs[index] : .init()
        }

        let inherited = style(at: prefix - 1)
        let insertedAfterList = new.count > old.count && old.count == prefix + suffix && inherited.bullet != nil
        let middle = insertedAfterList ? inherited : style(at: min(prefix, old.count - 1))
        var formats = new.indices.map { index in
            if index < prefix { return style(at: index) }
            if index >= new.count - suffix { return style(at: old.count - (new.count - index)) }
            let corresponding = prefix + min(index - prefix, max(0, old.count - prefix - suffix - 1))
            return corresponding < old.count && !insertedAfterList ? style(at: corresponding) : middle
        }
        let updated = prefix..<(new.count - suffix)
        var next = updated.lowerBound
        while next < updated.upperBound { next = SlideParagraph.renumberList(around: next, in: &formats) }
        if updated.isEmpty, prefix > 0 { SlideParagraph.renumberList(around: prefix - 1, in: &formats) }
        layout.paragraphs = formats
        textLayout = layout
    }

    var label: String {
        switch kind {
        case .text: return text.split(separator: "\n").first.map { String($0.prefix(26)) } ?? "文本框"
        case .image: return "图片"
        case .rectangle: return "矩形"
        case .table: return "表格"
        case .connector: return "连接线"
        }
    }
}

struct SlideCitation: Codable, Equatable {
    var quotation = ""
    var commentary = ""
    var source = ""
    var location = ""

    var reference: String {
        [source, location].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "，")
    }

    var handoutText: String {
        [("原文", quotation), ("注释", commentary), ("出处", reference)]
            .filter { !$0.1.isEmpty }.map { $0.0 + "　" + $0.1 }.joined(separator: "\n")
    }
}

struct Slide: Codable, Identifiable, Equatable {
    enum TeachingCue: String, Codable, CaseIterable, Identifiable {
        case essential = "必讲", optional = "可略", question = "提问", transition = "转场"
        var id: Self { self }
    }

    var id = UUID()
    var section = ""
    var background = Palette.paper
    var speakerNotes = ""
    var teachingCue: TeachingCue?
    var bookmarked: Bool?
    var citation: SlideCitation?
    var plannedChapterMinutes: Int?
    var objects: [SlideObject] = []
    var importReport: SlideImportReport?
    var hiddenInShow: Bool?

    var isBackup: Bool { hiddenInShow == true }

    var title: String {
        let title = objects.lazy.filter { $0.kind == .text && $0.decorationSource == nil }.map(\.label).first
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
    static let size = SlideCanvas.widescreen.size
    var schemaVersion = 1
    var slides: [Slide] = [Slide.titleSlide("新建课件", subtitle: "双击文字开始编辑")]
    var images: [UUID: Data] = [:]
    var importedTitle: String?
    var canvas: SlideCanvas?

    func editorPage(after index: Int, direction: Int, matching: Set<UUID>? = nil) -> UUID? {
        guard slides.indices.contains(index), direction == 1 || direction == -1 else { return nil }
        var next = index + direction
        while slides.indices.contains(next) {
            let id = slides[next].id
            if matching?.contains(id) != false { return id }
            next += direction
        }
        return nil
    }

    func firstPresentationIndex(at startingIndex: Int) -> Int? {
        guard !slides.isEmpty else { return nil }
        let start = min(max(0, startingIndex), slides.count - 1)
        if !slides[start].isBackup { return start }
        return presentationIndex(after: start, step: 1) ?? presentationIndex(after: start, step: -1)
    }

    func presentationIndex(after index: Int, step: Int) -> Int? {
        guard step == 1 || step == -1 else { return nil }
        var next = index + step
        while slides.indices.contains(next) {
            if !slides[next].isBackup { return next }
            next += step
        }
        return nil
    }

    func pagesForPDF(includeBackups: Bool) throws -> [(offset: Int, element: Slide)] {
        let pages = slides.enumerated().filter { includeBackups || !$0.element.isBackup }
        guard !pages.isEmpty else { throw SlideExportError.noRegularPages }
        return pages
    }

    func validated() throws -> Deck {
        guard schemaVersion == 1, canvas?.isValid != false else { throw CocoaError(.fileReadUnknown) }
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
                      (8...200).contains(object.fontSize), object.textLayout?.isValid != false,
                      object.characterStyle?.isValid != false, object.pictureCrop?.isValid != false,
                      object.pictureAppearance?.isValid != false, object.validTextRuns else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                guard object.kind != .table || object.table?.isValid == true,
                      object.kind != .connector || object.connector?.isValid == true else {
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

enum SlideExportError: LocalizedError {
    case noRegularPages

    var errorDescription: String? {
        "课件中只有备用页。请勾选「包含备用页」，或将至少一页设为正片。"
    }
}
