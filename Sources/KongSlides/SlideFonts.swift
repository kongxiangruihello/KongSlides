import AppKit
import CoreText
import SwiftUI

enum SlideFonts {
    static func named(_ name: String, size: CGFloat) -> NSFont? {
        if let font = NSFont(name: name, size: size) { return font }
        let family = NSFontManager.shared.availableFontFamilies.contains(name)
        return family ? NSFont(descriptor: NSFontDescriptor(fontAttributes: [.family: name]), size: size) : nil
    }

    static func typeface(_ name: String?, size: CGFloat, bold: Bool = false) -> NSFont {
        let fallback = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        guard let name, let font = named(name, size: size) else { return fallback }
        return bold ? NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.bold), size: size) ?? fallback : font
    }

    static func requested(in deck: Deck) -> [String] {
        let objects = deck.slides.lazy.flatMap(\.objects)
        let names = objects.flatMap { object -> [String] in
            let text = object.table?.cells.map(\.textObject) ?? (object.kind == .text ? [object] : [])
            return text.flatMap { item in
                [item.textLayout?.fontName].compactMap { $0 } + (item.textRuns ?? []).compactMap(\.fontName)
            }
        }
        return Set(names).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func replace(_ old: String, with replacement: String, in deck: inout Deck) {
        guard old != replacement else { return }
        func change(_ layout: inout SlideTextLayout?, _ runs: inout [SlideTextRun]?) {
            if layout?.fontName == old { layout?.fontName = replacement }
            guard var styled = runs else { return }
            for index in styled.indices where styled[index].fontName == old { styled[index].fontName = replacement }
            runs = styled
        }
        for slide in deck.slides.indices {
            for index in deck.slides[slide].objects.indices {
                var object = deck.slides[slide].objects[index]
                if object.kind == .text { change(&object.textLayout, &object.textRuns) }
                if var table = object.table {
                    for cell in table.cells.indices {
                        var updated = table.cells[cell]
                        change(&updated.layout, &updated.runs)
                        table.cells[cell] = updated
                    }
                    object.table = table
                }
                if object != deck.slides[slide].objects[index] { deck.slides[slide].objects[index] = object }
            }
        }
    }
}

struct CJKFontAudit {
    struct Finding {
        var missing: [Character] = []
        var substituted: [Character] = []
        var unavailable = Set<String>()
    }

    private struct Probe: Hashable {
        let glyph: Character
        let requested: String?
    }

    private enum Coverage {
        case available, substituted, missing
    }

    private var checked: [Probe: Coverage] = [:]
    private var fonts: [String: NSFont] = [:]
    private var unavailable = Set<String>()

    mutating func inspect(_ object: SlideObject) -> Finding {
        var result = Finding()
        var seenMissing = Set<Character>()
        var seenSubstitution = Set<Character>()
        for (segment, run) in object.textSegments(in: 0..<object.text.utf16.count) {
            let requested = run?.fontName ?? object.textLayout?.fontName
            let font: NSFont
            if let requested {
                if let known = fonts[requested] {
                    font = known
                } else if !unavailable.contains(requested), let found = SlideFonts.named(requested, size: 18) {
                    fonts[requested] = found
                    font = found
                } else {
                    unavailable.insert(requested)
                    result.unavailable.insert(requested)
                    font = NSFont.systemFont(ofSize: 18)
                }
            } else {
                font = NSFont.systemFont(ofSize: 18)
            }
            for char in segment where char.unicodeScalars.contains(where: Self.isCJK) {
                let probe = Probe(glyph: char, requested: requested)
                let value: Coverage
                if let existing = checked[probe] {
                    value = existing
                } else {
                    value = Self.coverage(char, using: font, explicit: requested != nil)
                    checked[probe] = value
                }
                switch value {
                case .missing:
                    if seenMissing.insert(char).inserted { result.missing.append(char) }
                case .substituted:
                    if seenSubstitution.insert(char).inserted { result.substituted.append(char) }
                case .available: break
                }
            }
        }
        return result
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (0x3400...0x4DBF).contains(value) || (0x4E00...0x9FFF).contains(value) ||
            (0xF900...0xFAFF).contains(value) || (0x20000...0x323AF).contains(value)
    }

    private static func coverage(_ character: Character, using font: NSFont, explicit: Bool) -> Coverage {
        let text = NSAttributedString(string: String(character), attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(text as CFAttributedString)
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun], !runs.isEmpty else { return .missing }
        var substituted = false
        var hasGlyph = false
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            hasGlyph = true
            var glyphs = [CGGlyph](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            if glyphs.contains(0) { return .missing }
            if explicit, let actual = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] {
                let raw = actual as CFTypeRef
                guard CFGetTypeID(raw) == CTFontGetTypeID() else { continue }
                let actualFont = unsafeBitCast(raw, to: CTFont.self)
                if (CTFontCopyFamilyName(actualFont) as String) != font.familyName { substituted = true }
            }
        }
        if !hasGlyph { return .missing }
        return substituted ? .substituted : .available
    }
}

struct FontReplacementView: View {
    let names: [String]
    let apply: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var source = ""
    @State private var replacement = ""
    @State private var families: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("全文替换字体").font(.title2.weight(.semibold))
            if names.isEmpty {
                Text("这份课件未指定字体，正文使用系统字体。").foregroundStyle(.secondary)
            } else {
                Picker("原字体", selection: $source) {
                    ForEach(names, id: \.self) { name in
                        Text(SlideFonts.named(name, size: 12) == nil ? "\(name)（本机缺少）" : name).tag(name)
                    }
                }
                Picker("替换为", selection: $replacement) {
                    Text("选择本机字体").tag("")
                    ForEach(families, id: \.self) { Text($0).tag($0) }
                }
                Text("将替换全课件中使用此字体的文本框和局部格式段，保留字号、颜色与上下标。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("替换") { apply(source, replacement); dismiss() }.keyboardShortcut(.defaultAction)
                    .disabled(source.isEmpty || replacement.isEmpty || source == replacement)
            }
        }
        .padding(22).frame(width: 450)
        .onAppear {
            source = names.first { SlideFonts.named($0, size: 12) == nil } ?? names.first ?? ""
            families = NSFontManager.shared.availableFontFamilies.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
    }
}
