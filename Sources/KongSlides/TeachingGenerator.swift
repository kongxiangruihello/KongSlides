import Foundation

enum TeachingGenerator {
    struct Layout {
        let clipboard: SlideClipboard
        let ranges: [UUID: Range<Int>]
    }

    static func generate(_ drafts: [TeachingDraft], template: TeachingTemplate) throws -> SlideClipboard {
        try layout(drafts, template: template).clipboard
    }

    static func layout(_ drafts: [TeachingDraft], template: TeachingTemplate) throws -> Layout {
        guard template.canGenerate else { throw TeachingOutlineError.boxTooSmall(template.name) }
        guard !drafts.isEmpty else { throw TeachingOutlineError.noContent }
        var pages: [Slide] = []
        var ranges: [UUID: Range<Int>] = [:]
        for draft in drafts {
            try Task.checkCancellation()
            let start = pages.count
            let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let safeTitle = title.isEmpty ? "未命名幻灯片" : title
            let bodySlot = template.slots[1]
            let textBox = template.slide.objects[bodySlot]
            let pieces = try divide(draft.projection, using: textBox, title: safeTitle)
            for (index, contents) in pieces.enumerated() {
                let name = index == 0 ? safeTitle : "\(safeTitle)（续 \(index)）"
                var slide = populated(draft, title: name, body: contents,
                                      notes: draft.notes(for: index + 1, pageCount: pieces.count), template: template)
                let titleSlot = template.slots[0]
                while SlideText.isClipped(slide.objects[titleSlot]), slide.objects[titleSlot].fontSize > 12 {
                    slide.objects[titleSlot].fontSize = max(12, slide.objects[titleSlot].fontSize - 2)
                }
                guard !SlideText.isClipped(slide.objects[titleSlot]) else {
                    throw TeachingOutlineError.boxTooSmall(safeTitle)
                }
                pages.append(slide)
                guard pages.count <= 500 else { throw TeachingOutlineError.tooLarge }
            }
            ranges[draft.id] = start..<pages.count
        }
        return Layout(clipboard: SlideClipboard(slides: pages, images: template.images, canvas: template.canvas), ranges: ranges)
    }

    private static func populated(_ draft: TeachingDraft, title: String, body: String, notes: String,
                                  template: TeachingTemplate) -> Slide {
        var slide = template.slide
        slide.id = UUID()
        slide.section = draft.section
        slide.speakerNotes = notes
        slide.objects[template.slots[0]].replaceText(with: title)
        slide.objects[template.slots[1]].replaceText(with: body)
        return slide
    }

    private static func divide(_ content: String, using box: SlideObject, title: String) throws -> [String] {
        guard !content.isEmpty else { return [""] }
        func fits(_ sample: ArraySlice<Character>) -> Bool {
            var object = box
            object.replaceText(with: String(sample))
            return !SlideText.isClipped(object)
        }

        let characters = Array(content)
        var pages: [String] = []
        var offset = 0
        while offset < characters.count {
            try Task.checkCancellation()
            let end = min(characters.count, offset + 4096)
            if fits(characters[offset..<end]) {
                pages.append(String(characters[offset..<end]))
                offset = end
            } else {
                var first = offset + 1
                var last = end - 1
                var boundary = offset
                while first <= last {
                    let middle = (first + last) / 2
                    if fits(characters[offset..<middle]) {
                        boundary = middle
                        first = middle + 1
                    } else {
                        last = middle - 1
                    }
                }
                guard boundary > offset else { throw TeachingOutlineError.boxTooSmall(title) }
                let recentStart = offset + (boundary - offset) / 2
                if let line = characters[recentStart..<boundary].lastIndex(of: "\n"), line > offset {
                    boundary = line + 1
                } else if let space = characters[recentStart..<boundary].lastIndex(where: { $0.isWhitespace }),
                          space > offset {
                    boundary = space + 1
                }
                pages.append(String(characters[offset..<boundary]))
                offset = boundary
            }
            guard pages.count <= 500 else { throw TeachingOutlineError.tooLarge }
        }
        return pages
    }
}
