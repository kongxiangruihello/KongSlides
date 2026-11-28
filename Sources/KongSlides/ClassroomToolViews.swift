import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

enum ClassroomToolSheet: String, Identifiable {
    case replace, batch, footer, shows, review, compatibility, studentTwo, studentThree, benchmark, toolbar
    var id: Self { self }
}

struct ReplaceDeckTextView: View {
    enum Scope: String, CaseIterable, Identifiable {
        case page = "当前页", section = "当前章", deck = "整份课件"
        var id: Self { self }
    }
    let deck: Deck
    let current: UUID
    let chapter: Set<UUID>
    let apply: ([DeckTextMatch], String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var replacement = ""
    @State private var scope = Scope.deck
    @State private var fields = Set(DeckTextField.allCases)
    @State private var matches: [DeckTextMatch] = []
    @State private var selected = Set<DeckTextMatch.ID>()
    @State private var previewPage: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("查找与替换").font(.title2.bold())
            HStack {
                TextField("查找文字", text: $query).onSubmit(preview)
                TextField("替换为（留空即删除）", text: $replacement)
                Picker("范围", selection: $scope) {
                    ForEach(Scope.allCases) { value in Text(value.rawValue).tag(value) }
                }.fixedSize()
            }
            HStack {
                ForEach(DeckTextField.allCases) { field in
                    Toggle(field.rawValue, isOn: Binding(get: { fields.contains(field) }, set: { enabled in
                        if enabled { fields.insert(field) } else { fields.remove(field) }
                    }))
                }
                Spacer()
                Button("预览匹配项", action: preview).disabled(query.isEmpty || fields.isEmpty)
            }
            HStack(spacing: 12) {
                List(matches, selection: $selected) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("第 \(entry.number) 页 · \(entry.id.field.rawValue)").font(.caption).foregroundStyle(.secondary)
                        Text(entry.snippet).lineLimit(2)
                    }.tag(entry.id)
                }.frame(width: 250)
                replacementPreview
            }
            HStack {
                Text("选中 \(selected.count) 项 / \(matches.count) 项").font(.caption)
                Button("全选") { selected = Set(matches.map(\.id)) }.disabled(matches.isEmpty)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("替换 \(selected.count) 处") { apply(matches.filter { selected.contains($0.id) }, replacement); dismiss() }
                    .disabled(selected.isEmpty)
            }
        }
        .padding(18).frame(width: 790, height: 475)
        .onChange(of: selected) {
            if let match = matches.first(where: { selected.contains($0.id) && $0.id.page == previewPage }) ?? matches.first(where: { selected.contains($0.id) }) {
                previewPage = match.id.page
            }
        }
        .onChange(of: query) { clear() }
        .onChange(of: fields) { clear() }
        .onChange(of: scope) { clear() }
    }

    @ViewBuilder
    private var replacementPreview: some View {
        let selectedMatches = matches.filter { selected.contains($0.id) }
        let pages = deck.slides.filter { page in selectedMatches.contains { $0.id.page == page.id } }
        if let page = pages.first(where: { $0.id == previewPage }) ?? pages.first {
            let matchesOnPage = selectedMatches.filter { $0.id.page == page.id }
            let updated = changedPage(page, matches: matchesOnPage)
            VStack(alignment: .leading, spacing: 7) {
                Picker("预览页面", selection: $previewPage) {
                    ForEach(pages) { item in Text(item.title).tag(Optional(item.id)) }
                }
                SlideChangePreview(before: page, after: updated, original: deck, revised: deck)
                if page.speakerNotes != updated.speakerNotes {
                    Text("讲稿 · \(shortNotes(page.speakerNotes)) → \(shortNotes(updated.speakerNotes))")
                        .font(.caption).lineLimit(2)
                }
                if page.section != updated.section {
                    Text("章名 · \(page.section) → \(updated.section)").font(.caption).lineLimit(1)
                }
            }
        } else {
            ContentUnavailableView("选择匹配项预览", systemImage: "rectangle.split.2x1")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func changedPage(_ page: Slide, matches: [DeckTextMatch]) -> Slide {
        var copy = deck.selectingPages([page.id])
        copy.replace(matches, with: replacement)
        return copy.slides.first ?? page
    }

    private func shortNotes(_ notes: String) -> String { String(notes.prefix(65)) }

    private func preview() {
        let pages: Set<UUID> = scope == .page ? [current] : scope == .section ? chapter : Set(deck.slides.map(\.id))
        matches = deck.matchingText(query, fields: fields, pages: pages)
        selected = Set(matches.map(\.id))
        previewPage = matches.first?.id.page
    }

    private func clear() { matches = []; selected = []; previewPage = nil }
}

struct BatchSlideStyleView: View {
    let deck: Deck
    let pages: [UUID]
    let apply: (Double?, String?, String?, Bool?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var updateTitle = false
    @State private var updateText = false
    @State private var updateBackground = false
    @State private var updateFooter = false
    @State private var showFooter = true
    @State private var titleSize = 40.0
    @State private var textColor = Palette.ink
    @State private var background = Palette.paper
    @State private var previewID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("批量调整 \(pages.count) 页").font(.title2.bold())
            HStack(spacing: 12) {
                List(pages, id: \.self, selection: $previewID) { id in
                    if let page = deck.slides.first(where: { $0.id == id }),
                       let index = deck.slides.firstIndex(where: { $0.id == id }) {
                        Text("第 \(index + 1) 页 · \(page.title)").tag(id)
                    }
                }.frame(width: 190)
                if let original = deck.slides.first(where: { $0.id == (previewID ?? pages.first) }) {
                    let revised = preview(of: original.id)
                    SlideChangePreview(before: original, after: revised.slides.first, original: deck, revised: revised)
                }
            }.frame(minHeight: 188)
            HStack {
                Toggle("标题字号", isOn: $updateTitle)
                TextField("字号", value: $titleSize, format: .number).frame(width: 65).disabled(!updateTitle)
            }
            HStack {
                Toggle("正文颜色", isOn: $updateText)
                colors($textColor).disabled(!updateText)
                Toggle("页背景", isOn: $updateBackground)
                colors($background).disabled(!updateBackground)
            }
            HStack {
                Toggle("调整页脚", isOn: $updateFooter)
                Picker("页脚", selection: $showFooter) {
                    Text("按课件设置显示").tag(true)
                    Text("隐藏").tag(false)
                }.disabled(!updateFooter)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("修改 \(pages.count) 页") {
                    apply(updateTitle ? min(200, max(8, titleSize)) : nil, updateText ? textColor : nil,
                          updateBackground ? background : nil, updateFooter ? showFooter : nil)
                    dismiss()
                }.disabled(!updateTitle && !updateText && !updateBackground && !updateFooter)
            }
        }.padding(20).frame(width: 755, height: 390)
         .onAppear { previewID = pages.first }
    }

    private func preview(of id: UUID) -> Deck {
        var revised = deck.selectingPages([id])
        revised.applyBatchStyle(to: [id], titleSize: updateTitle ? min(200, max(8, titleSize)) : nil,
                                bodyColor: updateText ? textColor : nil, background: updateBackground ? background : nil,
                                showFooter: updateFooter ? showFooter : nil)
        if updateFooter && !showFooter { revised.slides[0].objects.removeAll { $0.isCourseFooter == true } }
        return revised
    }

    private func colors(_ value: Binding<String>) -> some View {
        Picker("颜色", selection: value) {
            Text("墨黑").tag(Palette.ink)
            Text("靛蓝").tag(Palette.indigo)
            Text("米白").tag(Palette.paper)
            Text("纯白").tag("FFFFFF")
            Text("砖红").tag("A34E42")
        }.labelsHidden()
    }
}

struct CourseFooterView: View {
    let deck: Deck
    let current: Int
    let apply: (CourseFooter?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State var settings: CourseFooter
    @State var enabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("自动页码与课程页脚").font(.title2.bold())
            Toggle("启用课件页脚", isOn: $enabled)
            Group {
                TextField("课程名", text: $settings.course)
                TextField("学期", text: $settings.term)
                Toggle("显示章名", isOn: $settings.showChapter)
                Toggle("显示页码", isOn: $settings.showNumber)
                Toggle("备用页也编号", isOn: $settings.includeBackups)
                Toggle("封面和章首页隐藏页脚", isOn: $settings.hideChapterOpeners)
            }.disabled(!enabled)
            if deck.slides.indices.contains(current) {
                let slide = preview()
                SlideSurface(slide: slide, images: deck.images, canvas: deck.pageCanvas).frame(height: 156)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("应用到整份课件") { apply(enabled ? settings : nil); dismiss() }
            }
        }.padding(20).frame(width: 440)
    }

    private func preview() -> Slide {
        var preview = deck
        preview.courseFooter = enabled ? settings : nil
        preview.refreshCourseFooters()
        return preview.slides[current]
    }
}

struct ClassroomShowLibrary: View {
    let deck: Deck
    let selected: [UUID]
    let update: ([ClassroomShow]) -> Void
    let start: (ClassroomShow) -> Void
    @Environment(\.dismiss) private var dismiss
    @State var shows: [ClassroomShow]
    @State private var editingID: UUID?
    @State private var name = ""
    @State private var pages: [UUID] = []
    @State private var current: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("自定义放映顺序").font(.title2.bold())
            HStack {
                Menu("已有放映方案") {
                    ForEach(shows) { show in Button(show.name) { edit(show) } }
                }.disabled(shows.isEmpty)
                Button("新建方案") { edit(nil) }
                TextField("方案名称", text: $name)
            }
            HStack {
                List(deck.slides) { slide in
                    Button {
                        if pages.contains(slide.id) { pages.removeAll { $0 == slide.id } } else { pages.append(slide.id) }
                    } label: { Label(slide.title, systemImage: pages.contains(slide.id) ? "checkmark.circle.fill" : "plus.circle") }
                        .buttonStyle(.plain)
                }
                List(pages, id: \.self, selection: $current) { id in
                    Text(deck.slides.first { $0.id == id }?.title ?? "页面已删除").tag(id)
                }
            }
            HStack {
                Button("上移") { move(-1) }.disabled(current == nil)
                Button("下移") { move(1) }.disabled(current == nil)
                Button("删除方案", role: .destructive) {
                    shows.removeAll { $0.id == editingID }
                    update(shows)
                    edit(nil)
                }.disabled(editingID == nil)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存方案") { save() }.disabled(!canSave)
                Button("按此顺序放映") { if let show = save() { dismiss(); start(show) } }.disabled(!canSave)
            }
        }.padding(20).frame(width: 710, height: 455)
         .onAppear { edit(shows.first) }
    }

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !pages.isEmpty }

    private func edit(_ show: ClassroomShow?) {
        editingID = show?.id
        name = show?.name ?? ""
        let existing = Set(deck.slides.map(\.id))
        pages = (show?.pages ?? selected).filter { existing.contains($0) }
        current = nil
    }

    private func move(_ direction: Int) {
        guard let current, let index = pages.firstIndex(of: current), pages.indices.contains(index + direction) else { return }
        pages.swapAt(index, index + direction)
    }

    @discardableResult
    private func save() -> ClassroomShow? {
        guard canSave else { return nil }
        let show = ClassroomShow(id: editingID ?? UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines), pages: pages)
        if let index = shows.firstIndex(where: { $0.id == show.id }) { shows[index] = show }
        else { shows.append(show) }
        editingID = show.id
        update(shows)
        return show
    }
}

struct ClassroomReviewView: View {
    let review: ClassroomReview
    let deck: Deck
    let resume: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var page: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("课后回顾").font(.title2.bold())
            Text(review.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
            Text("讲到 \(title(review.lastPage))，共访问 \(review.visited.count) 页，跳过 \(review.skipped.count) 页。")
            if !review.skipped.isEmpty {
                DisclosureGroup("查看跳过的页面") {
                    ScrollView {
                        Text(review.skipped.map(title).joined(separator: "\n")).font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 85)
                }
            }
            List(review.chapters) { chapter in
                HStack {
                    Text(chapter.title)
                    Spacer()
                    Text("\(Int(chapter.seconds / 60)) 分 \(Int(chapter.seconds) % 60) 秒")
                    if let planned = chapter.plannedMinutes {
                        Text("计划 \(planned) 分").foregroundStyle(.secondary)
                        if chapter.seconds > Double(planned) * 60 { Text("超时").foregroundStyle(.orange) }
                    }
                }
            }
            HStack {
                Picker("下次开始", selection: $page) {
                    ForEach(deck.slides) { slide in Text(title(slide.id)).tag(Optional(slide.id)) }
                }
                Button("下次从这里继续") { if let page { resume(page); dismiss() } }.disabled(page == nil)
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(20).frame(width: 640, height: 425)
         .onAppear {
             page = [review.resumePage, review.lastPage].compactMap { $0 }.first { id in
                 deck.slides.contains { $0.id == id }
             } ?? deck.slides.first?.id
         }
    }

    private func title(_ id: UUID) -> String {
        guard let index = deck.slides.firstIndex(where: { $0.id == id }) else { return "已删除页面" }
        return "第 \(index + 1) 页 · \(deck.slides[index].title)"
    }
}

enum ClassroomWorkspaceLayout: String, CaseIterable, Identifiable {
    case full = "完整编辑", canvas = "专注画布", notes = "讲稿优先"
    var id: Self { self }
}

enum ClassroomOverflowAction { case grow, shrink, split }

enum ClassroomExportFormat {
    case powerPoint, projection
    var contentType: UTType { self == .powerPoint ? .slidePowerPoint : .pdf }
}

let classroomSlideDragType = "com.kongslides.internal-slide"

struct ClassroomDropHandler: DropDelegate {
    let entered: (Bool) -> Void
    let dropped: () -> Bool
    func dropEntered(info: DropInfo) { entered(true) }
    func dropExited(info: DropInfo) { entered(false) }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dropped() }
}

struct ClassroomRowDrag: ViewModifier {
    let enabled: Bool
    let destinationLabel: String?
    let after: Bool
    let provider: () -> NSItemProvider
    let entered: (Bool) -> Void
    let dropped: () -> Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .overlay(alignment: after ? .bottom : .top) {
                    if let destinationLabel {
                        VStack(alignment: .leading, spacing: 2) {
                            Rectangle().fill(Color.accentColor).frame(height: 2)
                            Text(destinationLabel).font(.caption2).foregroundStyle(Color.accentColor)
                                .padding(3).background(.regularMaterial, in: .rect(cornerRadius: 3))
                        }.frame(maxWidth: .infinity, alignment: .leading).allowsHitTesting(false)
                    }
                }
                .onDrag(provider)
                .onDrop(of: [classroomSlideDragType], delegate: ClassroomDropHandler(entered: entered, dropped: dropped))
        } else { content }
    }
}


struct SlideChangePreview: View {
    let before: Slide?
    let after: Slide?
    let original: Deck
    let revised: Deck

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            card("更改前", page: before, deck: original)
            card("更改后", page: after, deck: revised)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func card(_ title: String, page: Slide?, deck: Deck) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            if let page {
                SlideSurface(slide: page, images: deck.images, canvas: deck.pageCanvas)
                    .clipShape(.rect(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.28)))
            } else {
                Text("此版本没有该页面").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(maxWidth: .infinity)
    }
}
