import Foundation

struct SlideCharacterStyle: Codable, Equatable {
    var italic = false
    var underline = false
    var strikethrough = false
    var highlight: String?
    var spacing = 0.0
    var baseline = 0.0

    var isValid: Bool {
        (-1...1).contains(baseline) && (-40...40).contains(spacing) &&
            (highlight.map { $0.utf8.count == 6 && Int($0, radix: 16) != nil } ?? true)
    }
}

struct SlideTextRun: Codable, Equatable {
    var start: Int
    var length: Int
    var size: Double?
    var bold: Bool
    var color: String
    var fontName: String?
    var baseline: Double = 0
    var characterStyle: SlideCharacterStyle?
    var usesSystemFont: Bool?

    var end: Int { start + length }

    func matchesStyle(_ other: Self) -> Bool {
        size == other.size && bold == other.bold && color == other.color &&
            fontName == other.fontName && baseline == other.baseline && characterStyle == other.characterStyle &&
            usesSystemFont == other.usesSystemFont
    }
}

extension SlideObject {
    var baseTextStyle: SlideTextRun {
        var style = characterStyle
        let baseline = style?.baseline ?? 0
        style?.baseline = 0
        return SlideTextRun(start: 0, length: text.utf16.count, size: fontSize, bold: bold, color: color,
                            fontName: textLayout?.fontName, baseline: baseline, characterStyle: style)
    }

    func formattingStyles(in ranges: [Range<Int>]) -> [SlideTextRun] {
        let bounds = ranges.isEmpty ? [0..<text.utf16.count] : ranges
        let styles = bounds.flatMap { range in textSegments(in: range).map { $0.1 ?? baseTextStyle } }
        return styles.isEmpty ? [baseTextStyle] : styles
    }

    mutating func formatCharacters(in ranges: [Range<Int>], _ change: (inout SlideTextRun) -> Void) {
        let base = baseTextStyle
        if ranges.isEmpty {
            var updated = base
            change(&updated)
            fontSize = updated.size ?? fontSize
            bold = updated.bold
            color = updated.color
            if textLayout != nil || updated.fontName != nil {
                var layout = textLayout ?? .init()
                layout.fontName = updated.fontName
                textLayout = layout
            }
            var style = updated.characterStyle ?? .init()
            style.baseline = updated.baseline
            characterStyle = style == .init() ? nil : style
            if var runs = textRuns {
                for index in runs.indices { change(&runs[index]) }
                textRuns = runs
            }
            return
        }
        rewriteText(in: ranges) { value, existing in
            var style = existing ?? base
            change(&style)
            return (value, style)
        }
    }

    mutating func changeLetterCase(in ranges: [Range<Int>], uppercase: Bool) {
        let bounds = ranges.isEmpty ? [0..<text.utf16.count] : ranges
        rewriteText(in: bounds) { value, style in
            (uppercase ? value.uppercased() : value.lowercased(), style)
        }
    }

    private mutating func rewriteText(
        in ranges: [Range<Int>],
        _ change: (String, SlideTextRun?) -> (String, SlideTextRun?)
    ) {
        let length = text.utf16.count
        var result = ""
        var offset = 0
        var runs: [SlideTextRun] = []
        var cursor = 0
        func append(_ range: Range<Int>, changed: Bool) {
            for (piece, oldStyle) in textSegments(in: range) {
                let (value, style) = changed ? change(piece, oldStyle) : (piece, oldStyle)
                let count = value.utf16.count
                result += value
                if var run = style, count > 0 {
                    if let last = runs.indices.last, runs[last].end == offset, runs[last].matchesStyle(run) {
                        runs[last].length += count
                    } else {
                        run.start = offset
                        run.length = count
                        runs.append(run)
                    }
                }
                offset += count
            }
        }
        for range in ranges where range.lowerBound >= cursor && range.upperBound <= length {
            append(cursor..<range.lowerBound, changed: false)
            append(range, changed: true)
            cursor = range.upperBound
        }
        append(cursor..<length, changed: false)
        text = result
        textRuns = runs.isEmpty ? nil : runs
    }

    var paragraphStyles: [SlideParagraph] {
        let existing = textLayout?.paragraphs ?? []
        return text.components(separatedBy: "\n").indices.map { existing.indices.contains($0) ? existing[$0] : .init() }
    }

    func paragraphIndices(in ranges: [Range<Int>]) -> [Int] {
        let lines = text.components(separatedBy: "\n")
        guard !ranges.isEmpty else { return Array(lines.indices) }
        var offset = 0
        return lines.indices.filter { index in
            let start = offset
            offset += lines[index].utf16.count + 1
            return ranges.contains { $0.overlaps(start..<offset) }
        }
    }

    mutating func formatParagraphs(in ranges: [Range<Int>], _ change: (Int, inout SlideParagraph) -> Void) {
        var layout = textLayout ?? .init()
        var paragraphs = paragraphStyles
        for index in paragraphIndices(in: ranges) { change(index, &paragraphs[index]) }
        layout.paragraphs = paragraphs
        textLayout = layout
    }

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
                  (-1...1).contains(run.baseline), run.characterStyle?.isValid != false,
                  run.color.utf8.count == 6, Int(run.color, radix: 16) != nil else { return false }
            offset = run.end
        }
        return true
    }
}
