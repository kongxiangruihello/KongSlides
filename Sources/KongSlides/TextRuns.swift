import Foundation

struct SlideTextRun: Codable, Equatable {
    var start: Int
    var length: Int
    var size: Double?
    var bold: Bool
    var color: String
    var fontName: String?
    var baseline: Double = 0

    var end: Int { start + length }

    func matchesStyle(_ other: Self) -> Bool {
        size == other.size && bold == other.bold && color == other.color &&
            fontName == other.fontName && baseline == other.baseline
    }
}

extension SlideObject {
    func textSegments(in bounds: Range<Int>) -> [(String, SlideTextRun?)] {
        let source = text as NSString
        let runs = textRuns ?? []
        guard !bounds.isEmpty else { return [] }
        var result: [(String, SlideTextRun?)] = []
        var offset = bounds.lowerBound
        func append(_ range: Range<Int>, _ style: SlideTextRun?) {
            if !range.isEmpty {
                result.append((source.substring(with: NSRange(location: range.lowerBound, length: range.count)), style))
            }
        }
        for run in runs where run.end > bounds.lowerBound && run.start < bounds.upperBound {
            let start = max(offset, run.start)
            let end = min(run.end, bounds.upperBound)
            if start > offset { append(offset..<start, nil) }
            if end > start { append(start..<end, run) }
            offset = max(offset, end)
        }
        if offset < bounds.upperBound { append(offset..<bounds.upperBound, nil) }
        return result
    }

    mutating func remapTextRuns(to value: String) {
        guard let textRuns, !textRuns.isEmpty, text != value else { return }
        let old = Array(text)
        let new = Array(value)
        let prefixCount = zip(old, new).prefix { $0.0 == $0.1 }.count
        let suffixCount = zip(old.reversed(), new.reversed()).prefix(min(old.count, new.count) - prefixCount)
            .prefix { $0.0 == $0.1 }.count
        let start = String(old.prefix(prefixCount)).utf16.count
        let suffix = String(old.suffix(suffixCount)).utf16.count
        let oldEnd = text.utf16.count - suffix
        let newEnd = value.utf16.count - suffix
        let delta = newEnd - oldEnd
        let anchor = textRuns.last(where: { $0.start < start && $0.end >= start })
            ?? textRuns.first(where: { $0.start <= start && $0.end > start })
        var result: [SlideTextRun] = []
        func append(_ style: SlideTextRun, _ start: Int, _ end: Int) {
            guard end > start else { return }
            if let last = result.indices.last, result[last].end == start, result[last].matchesStyle(style) {
                result[last].length += end - start
            } else {
                var run = style
                run.start = start
                run.length = end - start
                result.append(run)
            }
        }
        for run in textRuns where run.start < start { append(run, run.start, min(run.end, start)) }
        if let anchor { append(anchor, start, newEnd) }
        for run in textRuns where run.end > oldEnd { append(run, max(run.start, oldEnd) + delta, run.end + delta) }
        self.textRuns = result.isEmpty ? nil : result
    }

    var validTextRuns: Bool {
        var offset = 0
        let count = text.utf16.count
        for run in textRuns ?? [] {
            guard run.start >= offset, run.start <= count, run.length > 0, run.length <= count - run.start,
                  run.size.map({ (8...200).contains($0) }) ?? true,
                  (-1...1).contains(run.baseline), run.color.utf8.count == 6, Int(run.color, radix: 16) != nil else { return false }
            offset = run.end
        }
        return true
    }
}
