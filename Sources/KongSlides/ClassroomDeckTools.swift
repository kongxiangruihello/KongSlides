import AppKit
import Foundation

enum ClassroomSlideFilter: String, CaseIterable, Identifiable {
    case all = "全部页面"
    case missingNotes = "没有讲稿"
    case missingCitation = "缺少出处"
    case backup = "备用页"
    case importIssues = "待处理导入问题"
    case teacherOnly = "教师专用页"

    var id: Self { self }

    func includes(_ slide: Slide) -> Bool {
        switch self {
        case .all: true
        case .missingNotes: slide.speakerNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .missingCitation: slide.citation?.reference.isEmpty != false
        case .backup: slide.isBackup
        case .importIssues: slide.importReport?.repair == nil && slide.importReport?.diagnostics.isEmpty == false
        case .teacherOnly: slide.teacherOnly == true
        }
    }
}

enum DeckTextField: String, CaseIterable, Identifiable {
    case body = "正文"
    case notes = "讲稿"
    case section = "章名"
    var id: Self { self }
}

struct DeckTextMatch: Identifiable {
    struct ID: Hashable {
        let page: UUID
        let object: UUID?
        let field: DeckTextField
        var cell: String?
        let range: NSRange
    }

    let id: ID
    let number: Int
    let snippet: String
    let original: String
}

extension Deck {
    func matchingText(_ query: String, fields: Set<DeckTextField>, pages: Set<UUID>) -> [DeckTextMatch] {
        guard !query.isEmpty else { return [] }
        return slides.enumerated().flatMap { index, slide -> [DeckTextMatch] in
            guard pages.contains(slide.id) else { return [] }
            func results(_ value: String, field: DeckTextField, object: UUID? = nil, cell: String? = nil) -> [DeckTextMatch] {
                guard fields.contains(field) else { return [] }
                let source = value as NSString
                var offset = 0
                var matches: [DeckTextMatch] = []
                while offset < source.length {
                    let range = source.range(of: query, options: .caseInsensitive,
                                             range: NSRange(location: offset, length: source.length - offset))
                    guard range.location != NSNotFound, range.length > 0 else { break }
                    let low = max(0, range.location - 18)
                    let high = min(source.length, NSMaxRange(range) + 24)
                    let snippet = source.substring(with: source.rangeOfComposedCharacterSequences(
                        for: NSRange(location: low, length: high - low)))
                    matches.append(.init(id: .init(page: slide.id, object: object, field: field, cell: cell, range: range),
                                         number: index + 1, snippet: snippet,
                                         original: source.substring(with: range)))
                    offset = NSMaxRange(range)
                }
                return matches
            }
            return results(slide.section, field: .section) + results(slide.speakerNotes, field: .notes) +
                slide.objects.filter { !$0.isLocked }.flatMap { object in
                    if let table = object.table {
                        return table.cells.flatMap { results($0.text, field: .body, object: object.id, cell: $0.id) }
                    }
                    return object.kind == .text ? results(object.text, field: .body, object: object.id) : []
                }
        }
    }

    mutating func replace(_ matches: [DeckTextMatch], with replacement: String) {
        let byPage = Dictionary(grouping: matches, by: \.id.page)
        for index in slides.indices {
            guard let pageMatches = byPage[slides[index].id] else { continue }
            for match in pageMatches.sorted(by: { $0.id.range.location > $1.id.range.location }) {
                func updated(_ text: String) -> String? {
                    let source = text as NSString
                    guard NSMaxRange(match.id.range) <= source.length,
                          source.substring(with: match.id.range) == match.original else { return nil }
                    return source.replacingCharacters(in: match.id.range, with: replacement)
                }
                switch match.id.field {
                case .body:
                    guard let object = slides[index].objects.firstIndex(where: { $0.id == match.id.object && !$0.isLocked }) else { continue }
                    if let cellID = match.id.cell, var table = slides[index].objects[object].table,
                       let cell = table.cells.firstIndex(where: { $0.id == cellID }), let value = updated(table.cells[cell].text) {
                        table.cells[cell].replaceText(with: value)
                        slides[index].objects[object].table = table
                    } else if match.id.cell == nil, let value = updated(slides[index].objects[object].text) {
                        slides[index].objects[object].replaceText(with: value)
                    }
                case .notes:
                    if let value = updated(slides[index].speakerNotes) { slides[index].speakerNotes = value }
                case .section:
                    if let value = updated(slides[index].section) { slides[index].section = value }
                }
            }
        }
    }

    func selectingPages(_ ids: Set<UUID>) -> Deck {
        var copy = self
        copy.slides = slides.filter { ids.contains($0.id) }
        return copy
    }

    func studentCopy(hideTeacherContent: Bool, includeBackups: Bool) -> Deck {
        var copy = self
        copy.slides.removeAll { (!includeBackups && $0.isBackup) || (hideTeacherContent && $0.teacherOnly == true) }
        if hideTeacherContent {
            for index in copy.slides.indices {
                copy.slides[index].objects.removeAll { $0.teacherOnly == true }
                copy.slides[index].speakerNotes = ""
                copy.slides[index].citation?.commentary = ""
            }
        }
        return copy
    }

    mutating func applyBatchStyle(to pages: Set<UUID>, titleSize: Double?, bodyColor: String?, background: String?, showFooter: Bool? = nil) {
        for index in slides.indices where pages.contains(slides[index].id) {
            if let background { slides[index].background = background }
            if let showFooter { slides[index].courseFooterHidden = showFooter ? nil : true }
            let text = slides[index].objects.indices.filter {
                slides[index].objects[$0].kind == .text && slides[index].objects[$0].decorationSource == nil &&
                    slides[index].objects[$0].isCourseFooter != true
            }
            if let title = text.first, let titleSize, !slides[index].objects[title].isLocked {
                slides[index].objects[title].formatCharacters(in: []) { $0.size = titleSize }
            }
            if let bodyColor {
                for object in text.dropFirst() where !slides[index].objects[object].isLocked {
                    slides[index].objects[object].formatCharacters(in: []) { $0.color = bodyColor }
                }
            }
        }
    }

    mutating func refreshCourseFooters() {
        guard courseFooter != nil || slides.contains(where: { $0.objects.contains(where: { $0.isCourseFooter == true }) }) else { return }
        let canvas = pageCanvas
        var number = 0
        for index in slides.indices {
            let previous = slides[index].objects.first { $0.isCourseFooter == true }
            slides[index].objects.removeAll { $0.isCourseFooter == true }
            guard let footer = courseFooter, !slides[index].isBackup || footer.includeBackups else { continue }
            number += 1
            let chapterStart = index == 0 || slides[index - 1].section != slides[index].section
            if slides[index].courseFooterHidden == true || (footer.hideChapterOpeners && chapterStart) { continue }
            var parts = [footer.course, footer.term]
            if footer.showChapter { parts.append(slides[index].section) }
            if footer.showNumber { parts.append("第 \(number) 页") }
            let value = parts.filter { !$0.isEmpty }.joined(separator: "  ·  ")
            guard !value.isEmpty else { continue }
            let pageHeight = max(12, min(21, canvas.height * 0.05))
            let bottomInset: Double = slides[index].citation?.reference.isEmpty == false ? 24 : 2
            var object = SlideObject(id: previous?.id ?? UUID(), x: canvas.width * 0.04,
                                     y: max(0, canvas.height - pageHeight - bottomInset), width: max(1, canvas.width * 0.92),
                                     height: pageHeight, text: value, fontSize: max(8, min(12, pageHeight - 3)),
                                     color: Palette.ink, locked: true)
            object.isCourseFooter = true
            slides[index].objects.append(object)
        }
    }
}

struct CourseFooter: Codable, Equatable {
    var course = ""
    var term = ""
    var showChapter = true
    var showNumber = true
    var includeBackups = false
    var hideChapterOpeners = false
}

struct RestorablePDFPage: Codable, Equatable {
    let background: String
    let objects: [SlideObject]
    let previousRepair: SlideImportReport.Repair?
}

struct ClassroomShow: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var pages: [UUID]

    func positions(in deck: Deck) -> [Int] {
        let indices = Dictionary(uniqueKeysWithValues: deck.slides.enumerated().map { ($0.element.id, $0.offset) })
        var seen = Set<UUID>()
        return pages.compactMap { seen.insert($0).inserted ? indices[$0] : nil }
    }
}

struct ClassroomReview: Codable, Equatable {
    struct Chapter: Codable, Equatable, Identifiable {
        var id: UUID
        var title: String
        var plannedMinutes: Int?
        var seconds: TimeInterval
    }

    let date: Date
    let lastPage: UUID
    let visited: [UUID]
    let skipped: [UUID]
    let chapters: [Chapter]
    var resumePage: UUID?
}

struct CanvasSnap {
    var delta: CGSize
    var x: CGFloat?
    var y: CGFloat?
    var xLabel: String?
    var yLabel: String?

    static func move(_ moved: CGRect, by delta: CGSize, anchors: [CGRect], tolerance: CGFloat) -> Self {
        let candidate = moved.offsetBy(dx: delta.width, dy: delta.height)
        func nearest(_ coordinates: [CGFloat], to targets: [CGFloat], labels: [String]) -> (CGFloat, CGFloat, String)? {
            var best: (CGFloat, CGFloat, String)?
            for (index, source) in coordinates.enumerated() {
                for target in targets {
                    let shift = target - source
                    if abs(shift) <= tolerance && (best == nil || abs(shift) < abs(best?.0 ?? 0)) {
                        best = (shift, target, labels[index])
                    }
                }
            }
            return best
        }
        func gaps(start: (CGRect) -> CGFloat, end: (CGRect) -> CGFloat, size: CGFloat) -> [CGFloat] {
            let sorted = anchors.sorted { start($0) < start($1) }
            return zip(sorted, sorted.dropFirst()).flatMap { first, second -> [CGFloat] in
                let gap = start(second) - end(first)
                guard gap >= 0 else { return [] }
                let before = start(first) - gap - size / 2
                let after = end(second) + gap + size / 2
                return gap >= size ? [before, (end(first) + start(second)) / 2, after] : [before, after]
            }
        }
        func closer(_ edge: (CGFloat, CGFloat, String)?, _ spacing: (CGFloat, CGFloat, String)?) -> (CGFloat, CGFloat, String)? {
            guard let edge, let spacing else { return edge ?? spacing }
            return abs(edge.0) <= abs(spacing.0) ? edge : spacing
        }
        let x = closer(nearest([candidate.minX, candidate.midX, candidate.maxX], to: anchors.flatMap { [$0.minX, $0.midX, $0.maxX] }, labels: ["左边缘", "水平居中", "右边缘"]),
                       nearest([candidate.midX], to: gaps(start: \.minX, end: \.maxX, size: candidate.width), labels: ["水平等距"]))
        let y = closer(nearest([candidate.minY, candidate.midY, candidate.maxY], to: anchors.flatMap { [$0.minY, $0.midY, $0.maxY] }, labels: ["上边缘", "垂直居中", "下边缘"]),
                       nearest([candidate.midY], to: gaps(start: \.minY, end: \.maxY, size: candidate.height), labels: ["垂直等距"]))
        return Self(delta: CGSize(width: delta.width + (x?.0 ?? 0), height: delta.height + (y?.0 ?? 0)), x: x?.1, y: y?.1, xLabel: x?.2, yLabel: y?.2)
    }
}
