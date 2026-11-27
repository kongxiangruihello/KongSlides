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
        let impact: ImportDiagnostic.Impact?
    }

    var id: ID { ID(slide: slideID, object: objectID, title: title, detail: detail, impact: impact) }
    let slideID: UUID
    let objectID: UUID?
    var page: Int
    let title: String
    let detail: String
    var source: String? = nil
    var impact: ImportDiagnostic.Impact? = nil
    var repair: SlideImportReport.Repair? = nil

    static func imported(_ deck: Deck) -> [Self] {
        let rows = deck.slides.enumerated().flatMap { index, slide -> [Self] in
            guard let report = slide.importReport else { return [] }
            return report.diagnostics.map { issue in
                Self(slideID: slide.id, objectID: issue.objectID, page: index + 1, title: issue.title,
                     detail: issue.detail, source: "\(report.sourceName) · 源第 \(report.sourcePage) 页", impact: issue.impact, repair: report.repair)
            }
        }
        return ImportDiagnostic.Impact.allCases.flatMap { impact in rows.filter { $0.impact == impact } }
    }

    static func exportTSV(_ deck: Deck) -> String {
        let header = ["处理状态", "当前页", "源文件及页码", "影响程度", "问题", "详情", "修复来源"]
        let data = imported(deck).map { row in
            [row.repair == nil ? "待处理" : "已用 PDF 替换", String(row.page), row.source ?? "",
             row.impact?.title ?? "", row.title, row.detail,
             row.repair.map { "\($0.pdfName) 第 \($0.pdfPage) 页" } ?? ""]
        }
        return ([header] + data).map { cells in
            cells.map { cell in
                let value = cell.components(separatedBy: .newlines.union(.controlCharacters)).joined(separator: " ")
                let first = value.trimmingCharacters(in: .whitespaces).first
                return first.map { "=+-@".contains($0) } == true ? "'" + value : value
            }.joined(separator: "\t")
        }.joined(separator: "\n") + "\n"
    }

    static func preflight(_ deck: Deck) -> [Self] {
        let canvas = CGRect(origin: .zero, size: deck.pageCanvas.size).insetBy(dx: -0.1, dy: -0.1)
        var fontAudit = CJKFontAudit()
        return deck.slides.enumerated().flatMap { index, slide in
            slide.objects.flatMap { object -> [Self] in
                var rows: [Self] = []
                func add(_ title: String, _ detail: String) {
                    rows.append(Self(slideID: slide.id, objectID: object.id, page: index + 1,
                                     title: title, detail: detail))
                }
                let bounds = object.pictureAppearance?.bounds(of: object.frame) ?? object.frame
                if !canvas.contains(bounds) {
                    add(object.kind == .image ? "图片超出画布" : "对象超出画布",
                        "「\(object.label)」的画布外部分在放映和 PDF 中会被裁掉。")
                }
                if object.kind == .text {
                    if SlideText.isClipped(object) {
                        add("文字可能截断", "「\(object.label)」的内容超出了文字可用区域。可增大文本框或调小字号。")
                    }
                    let finding = fontAudit.inspect(object)
                    if !finding.unavailable.isEmpty {
                        add("字体缺失", finding.unavailable.sorted().joined(separator: "、"))
                    }
                    if !finding.missing.isEmpty {
                        let chars = finding.missing.prefix(16).map {
                            String($0) + " " + $0.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
                        }
                        add("中文字符缺字", chars.joined(separator: "、"))
                    }
                    if !finding.substituted.isEmpty {
                        add("中文字符使用替代字体", String(finding.substituted.prefix(24)))
                    }
                }
                return rows
            }
        }
    }
}

struct ImportReviewSummary {
    let total: Int
    let readable: Int
    let repaired: Int
    let pending: [SlideReviewRow]

    init(total: Int, rows: [SlideReviewRow]) {
        let failures = rows.filter { $0.impact == .pageUnavailable }.sorted { $0.page < $1.page }
        var seen = Set<UUID>()
        let pages = failures.filter { seen.insert($0.slideID).inserted }
        self.total = total
        readable = max(0, total - pages.count)
        repaired = pages.count(where: { $0.repair != nil })
        pending = pages.filter { $0.repair == nil }
    }

    func next(after page: Int) -> SlideReviewRow? {
        pending.first { $0.page > page } ?? pending.first
    }
}

struct SlideReviewPanel: View {
    let mode: SlideReviewMode
    let rows: [SlideReviewRow]
    let pageCount: Int
    let currentPage: Int
    let checking: Bool
    let refresh: () -> Void
    let compare: () -> Void
    let repair: (SlideReviewRow) -> Void
    let exportReport: () -> Void
    let fonts: () -> Void
    let close: () -> Void
    let reveal: (SlideReviewRow) -> Void

    @State private var impactFilter: ImportDiagnostic.Impact?
    @State private var includeProcessed = false
    private var summary: ImportReviewSummary { ImportReviewSummary(total: pageCount, rows: rows) }
    private var filteredRows: [SlideReviewRow] {
        mode == .imported && !includeProcessed ? rows.filter { $0.repair == nil } : rows
    }
    private var shownRows: [SlideReviewRow] {
        guard mode == .imported, let impactFilter else { return filteredRows }
        return filteredRows.filter { $0.impact == impactFilter }
    }

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
                Button("替换字体…", action: fonts)
                if mode == .preflight {
                    Button("重新检查", action: refresh).disabled(checking)
                } else {
                    Button("对照原稿 PDF…", action: compare)
                    Button("导出清单…", action: exportReport).disabled(rows.isEmpty)
                }
                Button(action: close) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭检查面板")
            }
            if mode == .imported {
                HStack(spacing: 8) {
                    Picker("影响程度", selection: $impactFilter) {
                        Text("全部（\(filteredRows.count)）").tag(nil as ImportDiagnostic.Impact?)
                        ForEach(ImportDiagnostic.Impact.allCases) { impact in
                            let count = filteredRows.count(where: { $0.impact == impact })
                            Text("\(impact.title)（\(count)）").tag(Optional(impact))
                        }
                    }
                    .fixedSize()
                    Toggle("显示已处理", isOn: $includeProcessed)
                    Spacer(minLength: 0)
                }
            }
            if mode == .imported {
                HStack(spacing: 10) {
                    Text("共 \(summary.total) 页 · 已读 \(summary.readable) · 已修复 \(summary.repaired) · 待修复 \(summary.pending.count)")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Spacer(minLength: 0)
                    if let first = summary.pending.first {
                        Button("首个失败页") { reveal(first) }
                        Button("处理下一页…") {
                            if let next = summary.next(after: currentPage) { repair(next) }
                        }
                    }
                }
            }
            if shownRows.isEmpty {
                Text(checking ? "正在检查课件…" : mode == .preflight
                     ? "未发现需处理的文字、字体或画布问题。"
                     : rows.isEmpty ? "导入时未记录需要核对的项目。" : "没有符合筛选条件的条目。")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(shownRows) { row in
                            HStack {
                                Button { reveal(row) } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        Text("第 \(row.page) 页").monospacedDigit()
                                            .frame(width: 62, alignment: .leading)
                                            .foregroundStyle(Color.accentColor)
                                        VStack(alignment: .leading, spacing: 3) {
                                            HStack(spacing: 8) {
                                                Text(row.title).fontWeight(.medium)
                                                if let impact = row.impact {
                                                    Text(impact.title)
                                                        .font(.caption)
                                                        .foregroundStyle(impact == .pageUnavailable ? Color.red :
                                                            impact == .contentMissing ? Color.orange : Color.secondary)
                                                }
                                            }
                                            Text(row.detail).foregroundStyle(.secondary)
                                            if let repair = row.repair {
                                                Text("已用 \(repair.pdfName) 第 \(repair.pdfPage) 页替换")
                                                    .font(.caption).foregroundStyle(.secondary)
                                            }
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
                                if row.impact == .pageUnavailable && row.repair == nil {
                                    Button("用 PDF 修复…") { repair(row) }
                                }
                            }
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(11)
        .frame(height: mode == .imported ? 220 : 168)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
