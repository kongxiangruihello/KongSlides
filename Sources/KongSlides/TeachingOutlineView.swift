import SwiftUI

struct TeachingOutlineView: View {
    let templates: [TeachingTemplate]
    let insert: (SlideClipboard) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var source = ""
    @State private var defaultDestination: TeachingDestination = .projection
    @State private var drafts: [TeachingDraft] = []
    @State private var selected: UUID?
    @State private var templateID: UUID?
    @State private var error: String?
    @State private var building = false

    private var template: TeachingTemplate {
        templates.first { $0.id == templateID } ?? TeachingTemplate.classroom
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("从提纲生成课件").font(.title2.weight(.semibold))
            if drafts.isEmpty {
                sourcePane
            } else {
                previewPane
            }
            Divider()
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(building)
                Spacer()
                if building { ProgressView().controlSize(.small) }
                if drafts.isEmpty {
                    Button("解析并预览", action: parse).keyboardShortcut(.defaultAction)
                        .disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Button("返回原文") { drafts = []; error = nil }
                        .disabled(building)
                    Button("插入课件", action: generate).keyboardShortcut(.defaultAction)
                        .disabled(building)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 900, minHeight: 590)
        .interactiveDismissDisabled(building)
    }

    private var sourcePane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("粘贴 Markdown 提纲或逐字讲稿。# 写课程名，## 分章节，### 新起一页。可用【投影】和【讲稿】指定内容去向。")
                .foregroundStyle(.secondary)
            HStack {
                Picker("未标记的段落放到", selection: $defaultDestination) {
                    ForEach(TeachingDestination.allCases) { kind in Text(kind.label).tag(kind) }
                }
                Spacer()
                Button("载入示例") { source = TeachingOutline.example; error = nil }
            }
            TextEditor(text: $source)
                .font(.system(.body, design: .monospaced))
                .border(.secondary.opacity(0.25))
                .accessibilityLabel("提纲或讲稿原文")
        }
    }

    private var previewPane: some View {
        HStack(spacing: 15) {
            List(selection: $selected) {
                ForEach(Array(drafts.enumerated()), id: \.element.id) { number, draft in
                    VStack(alignment: .leading, spacing: 3) {
                        if !draft.section.isEmpty {
                            Text(draft.section).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Text("\(number + 1)  \(draft.title)").lineLimit(2)
                    }.tag(draft.id)
                }
            }
            .frame(width: 188)
            if let index = drafts.firstIndex(where: { $0.id == selected }) {
                draftPane($drafts[index])
            }
        }
        .disabled(building)
    }

    private func draftPane(_ draft: Binding<TeachingDraft>) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("幻灯片标题", text: draft.title).textFieldStyle(.roundedBorder)
                Picker("教学版式", selection: $templateID) {
                    ForEach(templates) { item in Text(item.name).tag(Optional(item.id)) }
                }
                SlideSurface(slide: TeachingGenerator.preview(draft.wrappedValue, template: template), images: template.images)
                    .border(.secondary.opacity(0.25))
                Text("投影文字过长时会生成续页。对应讲稿保存在该组的首页。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(minWidth: 300, maxWidth: 410)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(draft.blocks) { block in
                        VStack(alignment: .leading, spacing: 6) {
                            Picker("显示在", selection: block.destination) {
                                ForEach(TeachingDestination.allCases) { kind in Text(kind.label).tag(kind) }
                            }.pickerStyle(.segmented)
                            TextEditor(text: block.text)
                                .font(.body).frame(height: 88)
                                .border(.secondary.opacity(0.25))
                                .accessibilityLabel("内容段落")
                        }
                    }
                    Button("添加段落") {
                        draft.wrappedValue.blocks.append(TeachingBlock(text: "", destination: .notes))
                    }
                }
                .padding(.trailing, 4)
            }
            .frame(minWidth: 235)
        }
    }

    private func parse() {
        do {
            drafts = try TeachingOutline.parse(source, defaultDestination: defaultDestination)
            selected = drafts.first?.id
            templateID = templateID ?? templates.first?.id
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func generate() {
        let input = drafts
        let style = template
        building = true
        error = nil
        Task { @MainActor in
            defer { building = false }
            do {
                let pages = try await Task.detached(priority: .userInitiated) {
                    try TeachingGenerator.generate(input, template: style)
                }.value
                insert(pages)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
