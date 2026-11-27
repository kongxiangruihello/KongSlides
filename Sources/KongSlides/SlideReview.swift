import SwiftUI

enum SlideReviewMode {
    case imported
    case preflight

    var title: String {
        self == .imported ? "PPTX 导入报告" : "放映前检查"
    }
}

struct SlideReviewRow: Identifiable {
    struct ID: Hashable {
        let slide: UUID
        let object: UUID?
        let title: String
        let detail: String
    }

    var id: ID { ID(slide: slideID, object: objectID, title: title, detail: detail) }
    let slideID: UUID
    let objectID: UUID?
    var page: Int
    let title: String
    let detail: String
    var source: String? = nil

    static func imported(_ deck: Deck) -> [Self] {
        deck.slides.enumerated().flatMap { index, slide -> [Self] in
            guard let report = slide.importReport else { return [] }
            return report.diagnostics.map { issue in
                Self(slideID: slide.id, objectID: issue.objectID, page: index + 1, title: issue.kind.title,
                     detail: issue.detail, source: "\(report.sourceName) · 源第 \(report.sourcePage) 页")
            }
        }
    }

    static func preflight(_ deck: Deck) -> [Self] {
        let canvas = CGRect(origin: .zero, size: deck.pageCanvas.size).insetBy(dx: -0.1, dy: -0.1)
        return deck.slides.enumerated().flatMap { index, slide in
            slide.objects.flatMap { object -> [Self] in
                var rows: [Self] = []
                func add(_ title: String, _ detail: String) {
                    rows.append(Self(slideID: slide.id, objectID: object.id, page: index + 1,
                                     title: title, detail: detail))
                }
                if !canvas.contains(object.frame) {
                    add(object.kind == .image ? "图片超出画布" : "对象超出画布",
                        "「\(object.label)」的画布外部分在放映和 PDF 中会被裁掉。")
                }
                if object.kind == .text && SlideText.isClipped(object) {
                    add("文字可能截断", "「\(object.label)」的内容超出了文字可用区域。可增大文本框或调小字号。")
                }
                return rows
            }
        }
    }
}

struct SlideReviewPanel: View {
    let mode: SlideReviewMode
    let rows: [SlideReviewRow]
    let pageCount: Int
    let checking: Bool
    let refresh: () -> Void
    let compare: () -> Void
    let close: () -> Void
    let reveal: (SlideReviewRow) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Text(mode.title).font(.headline)
                if checking {
                    ProgressView().controlSize(.small)
                } else {
                    Text("\(pageCount) 页 · \(rows.count) 项").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if mode == .preflight {
                    Button("重新检查", action: refresh).disabled(checking)
                } else {
                    Button("对照原稿 PDF…", action: compare)
                }
                Button(action: close) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭检查面板")
            }
            if mode == .imported {
                Text("记录导入时的转换情况。页码随当前课件顺序更新。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if rows.isEmpty {
                Text(checking ? "正在检查课件…" : mode == .preflight
                     ? "未发现文字截断或对象超出画布。" : "导入时未记录需要核对的项目。")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            Button { reveal(row) } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Text("第 \(row.page) 页").monospacedDigit()
                                        .frame(width: 62, alignment: .leading)
                                        .foregroundStyle(Color.accentColor)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(row.title).fontWeight(.medium)
                                        Text(row.detail).foregroundStyle(.secondary)
                                        if let source = row.source {
                                            Text(source).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(11)
        .frame(height: 168)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
