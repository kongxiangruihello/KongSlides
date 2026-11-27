import Foundation

struct SlideSearchHit {
    let field: String
    let before: String
    let match: String
    let after: String

    static func first(on slide: Slide, query: String) -> Self? {
        guard !query.isEmpty else { return nil }
        func hit(_ value: String, field: String) -> Self? {
            guard let range = value.range(of: query, options: .caseInsensitive, locale: .current) else { return nil }
            let prefix = value[..<range.lowerBound].suffix(15)
            let suffix = value[range.upperBound...].prefix(23)
            return Self(field: field, before: (prefix.count > 14 ? "…" : "") + String(prefix.suffix(14)),
                        match: String(value[range]), after: String(suffix.prefix(22)) + (suffix.count > 22 ? "…" : ""))
        }
        if let match = hit(slide.title, field: "标题") { return match }
        if let match = hit(slide.section, field: "章节") { return match }
        for object in slide.objects {
            if object.kind == .text, let match = hit(object.text, field: "正文") { return match }
            if let table = object.table {
                for cell in table.cells {
                    if let match = hit(cell.text, field: "表格") { return match }
                }
            }
        }
        return hit(slide.speakerNotes, field: "讲稿")
    }
}
