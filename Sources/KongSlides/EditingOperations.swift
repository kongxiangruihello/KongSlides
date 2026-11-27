import Foundation

struct PictureCrop: Codable, Equatable {
    var left = 0.0
    var top = 0.0
    var right = 0.0
    var bottom = 0.0

    var isValid: Bool {
        [left, top, right, bottom].allSatisfy { (0...0.99).contains($0) } &&
            left + right <= 0.99 && top + bottom <= 0.99
    }

    static func filling(image: CGSize, frame: CGSize) -> Self {
        let imageRatio = image.width / image.height
        let frameRatio = frame.width / frame.height
        if imageRatio > frameRatio {
            let edge = min(0.495, (1 - frameRatio / imageRatio) / 2)
            return Self(left: edge, right: edge)
        }
        let edge = min(0.495, (1 - imageRatio / frameRatio) / 2)
        return Self(top: edge, bottom: edge)
    }

    func imageRect(inside frame: CGRect) -> CGRect {
        let width = frame.width / (1 - left - right)
        let height = frame.height / (1 - top - bottom)
        return CGRect(x: frame.minX - left * width, y: frame.minY - bottom * height,
                      width: width, height: height)
    }
}

enum ResizeCorner: CaseIterable, Hashable {
    case topLeft, topRight, bottomLeft, bottomRight

    var left: Bool { self == .topLeft || self == .bottomLeft }
    var top: Bool { self == .topLeft || self == .topRight }

    func resized(_ frame: CGRect, translation: CGSize, proportional: Bool) -> CGRect {
        let deltaX = translation.width * (left ? -1 : 1)
        let deltaY = translation.height * (top ? -1 : 1)
        var width = min(1920, max(min(12, frame.width), frame.width + deltaX))
        var height = min(1080, max(min(12, frame.height), frame.height + deltaY))
        if proportional {
            let xScale = deltaX / frame.width
            let yScale = deltaY / frame.height
            let preferred = 1 + (abs(xScale) >= abs(yScale) ? xScale : yScale)
            let minimum = max(min(12, frame.width) / frame.width, min(12, frame.height) / frame.height)
            let maximum = max(1, min(1920 / frame.width, 1080 / frame.height))
            let scale = min(maximum, max(minimum, preferred))
            width = frame.width * scale
            height = frame.height * scale
        }
        return CGRect(x: left ? frame.maxX - width : frame.minX, y: top ? frame.maxY - height : frame.minY,
                      width: width, height: height)
    }
}

struct SlideClipboard: Codable {
    var slides: [Slide]
    var images: [UUID: Data]
    var canvas: SlideCanvas?

    init(slides: [Slide], images: [UUID: Data], canvas: SlideCanvas? = nil) {
        self.slides = slides
        self.canvas = canvas
        let assetIDs = Set(slides.flatMap { $0.objects.compactMap(\.imageID) })
        self.images = images.filter { assetIDs.contains($0.key) }
    }

    func validated() throws -> Self {
        guard !slides.isEmpty, slides.count <= 500 else { throw CocoaError(.fileReadCorruptFile) }
        let value = try Deck(slides: slides, images: images, canvas: canvas).validated()
        return Self(slides: value.slides, images: value.images, canvas: canvas)
    }

    func copies(into deck: inout Deck) -> [Slide] {
        var assetMap: [UUID: UUID] = [:]
        for (id, data) in images {
            let target = deck.images[id].map { $0 != data } == true ? UUID() : id
            assetMap[id] = target
            deck.images[target] = data
        }
        let source = canvas ?? .widescreen
        let target = deck.pageCanvas
        return slides.map { slide in
            var copy = slide
            copy.id = UUID()
            copy.importReport = nil
            var groups: [UUID: UUID] = [:]
            let ids = Dictionary(uniqueKeysWithValues: slide.objects.map { ($0.id, UUID()) })
            copy.objects = slide.objects.map { object in
                var result = source.fitting(object, into: target)
                result.id = ids[object.id] ?? UUID()
                func copiedAttachment(_ link: SlideConnector.Attachment?) -> SlideConnector.Attachment? {
                    guard let link, let id = ids[link.objectID] else { return nil }
                    return .init(objectID: id, edge: link.edge)
                }
                if let line = result.connector {
                    result.connector?.startAttachment = copiedAttachment(line.startAttachment)
                    result.connector?.endAttachment = copiedAttachment(line.endAttachment)
                }
                if let group = object.groupID {
                    let copy = groups[group] ?? UUID()
                    groups[group] = copy
                    result.groupID = copy
                }
                if let asset = object.imageID { result.imageID = assetMap[asset] ?? asset }
                return result
            }
            return copy
        }
    }
}

extension Deck {
    mutating func moveSelectedSlides(_ ids: Set<UUID>, by delta: Int) {
        guard !ids.isEmpty, abs(delta) == 1 else { return }
        let offsets = slides.indices.filter { ids.contains(slides[$0].id) }
        guard let first = offsets.first, let last = offsets.last,
              first + delta >= 0, last + delta < slides.count else { return }
        for index in delta < 0 ? offsets : Array(offsets.reversed()) {
            slides.swapAt(index, index + delta)
        }
    }
}

struct SidebarPageSelection: Equatable {
    enum Click {
        case single, toggle, range, extendRange
    }

    var current: UUID
    var selected: Set<UUID>
    var anchor: UUID

    mutating func click(_ page: UUID, in visible: [UUID], mode: Click) {
        guard let target = visible.firstIndex(of: page) else { return }
        switch mode {
        case .single:
            current = page
            selected = [page]
            anchor = page
        case .toggle:
            if selected.contains(page) && selected.count > 1 {
                selected.remove(page)
                if current == page {
                    current = visible.enumerated().filter { selected.contains($0.element) }
                        .min { abs($0.offset - target) < abs($1.offset - target) }?.element ?? page
                    if current == page { selected = [page] }
                }
            } else {
                selected.insert(page)
                current = page
            }
            anchor = current
        case .range, .extendRange:
            let start = visible.firstIndex(of: anchor) ?? visible.firstIndex(of: current) ?? target
            let range = Set(visible[min(start, target)...max(start, target)])
            selected = mode == .extendRange ? selected.union(range) : range
            current = page
            anchor = visible[start]
        }
    }
}

enum SlidePageNumber {
    static func parse(_ input: String, pageCount: Int) -> Int? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? trimmed
        guard digits.utf8.allSatisfy({ (48...57).contains($0) }),
              let page = Int(digits), page >= 1, page <= pageCount else { return nil }
        return page
    }
}

struct SlideVisitHistory {
    private var back: [UUID] = []
    private var forward: [UUID] = []

    mutating func visit(from current: UUID, to target: UUID) {
        guard current != target else { return }
        Self.push(current, onto: &back)
        forward.removeAll()
    }

    mutating func step(from current: UUID, backward: Bool, available: Set<UUID>) -> UUID? {
        if backward {
            while let page = back.popLast() {
                if page != current && available.contains(page) {
                    Self.push(current, onto: &forward)
                    return page
                }
            }
        } else {
            while let page = forward.popLast() {
                if page != current && available.contains(page) {
                    Self.push(current, onto: &back)
                    return page
                }
            }
        }
        return nil
    }

    private static func push(_ page: UUID, onto stack: inout [UUID]) {
        if stack.last != page { stack.append(page) }
        if stack.count > 100 { stack.removeFirst(stack.count - 100) }
    }
}
