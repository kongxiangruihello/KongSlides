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
    @State private var preview: ComputedPreview?
    @State private var previewIndex = 0

    private struct PreviewInput: Equatable {
        let drafts: [TeachingDraft]
        let style: UUID
    }

    private struct ComputedPreview {
        let input: PreviewInput
        let layout: TeachingGenerator.Layout
    }

    private var previewInput: PreviewInput { PreviewInput(drafts: drafts, style: template.id) }
    private var currentLayout: TeachingGenerator.Layout? { preview?.input == previewInput ? preview?.layout : nil }

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
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if drafts.isEmpty {
                    Button("解析并预览", action: parse).keyboardShortcut(.defaultAction)
                        .disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    if let layout = currentLayout {
                        Text("将插入 \(layout.clipboard.slides.count) 页").foregroundStyle(.secondary)
                    } else if error == nil {
                        ProgressView().controlSize(.small)
                        Text("计算实际分页…").foregroundStyle(.secondary)
                    }
                    Button("返回原文") { drafts = []; error = nil }
                    Button("插入课件", action: insertPreview).keyboardShortcut(.defaultAction)
                        .disabled(currentLayout == nil)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 900, minHeight: 590)
        .task(id: previewInput) { await refreshPreview() }
        .onChange(of: selected) { previewIndex = 0 }
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
                        if let range = currentLayout?.ranges[draft.id] {
                            Text(range.count == 1 ? "实际第 \(range.lowerBound + 1) 页" :
                                 "实际第 \(range.lowerBound + 1)–\(range.upperBound) 页 · 含续页")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.tag(draft.id)
                }
            }
            .frame(width: 188)
            if let index = drafts.firstIndex(where: { $0.id == selected }) {
                draftPane($drafts[index])
            }
        }
    }

    private func draftPane(_ draft: Binding<TeachingDraft>) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("幻灯片标题", text: draft.title).textFieldStyle(.roundedBorder)
                Picker("教学版式", selection: $templateID) {
                    ForEach(templates) { item in Text(item.name).tag(Optional(item.id)) }
                }
                if let layout = currentLayout, let range = layout.ranges[draft.wrappedValue.id] {
                    let index = min(previewIndex, range.count - 1)
                    let page = layout.clipboard.slides[range.lowerBound + index]
                    SlideSurface(slide: page, images: layout.clipboard.images, canvas: layout.clipboard.canvas ?? .widescreen).border(.secondary.opacity(0.25))
                    HStack {
                        Button("上一张") { previewIndex = index - 1 }.disabled(index == 0)
                        Text("第 \(index + 1) / \(range.count) 张").monospacedDigit()
                        Button("下一张") { previewIndex = index + 1 }.disabled(index + 1 >= range.count)
                    }
                } else {
                    Text("更改后将重新排版。").font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 153)
                }
                Button("与下一组合并", action: mergeNext)
                    .disabled(!canMergeNext)
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
                            if block.wrappedValue.destination == .notes,
                               let count = currentLayout?.ranges[draft.wrappedValue.id]?.count, count > 1 {
                                Picker("讲稿放到", selection: Binding(
                                    get: { min(count, block.wrappedValue.notesPage) },
                                    set: { block.wrappedValue.notesPage = $0 }
                                )) {
                                    ForEach(1...count, id: \.self) { number in
                                        Text(number == 1 ? "首页" : "续页 \(number - 1)").tag(number)
                                    }
                                }
                            }
                            TextEditor(text: block.text)
                                .font(.body).frame(height: 88)
                                .border(.secondary.opacity(0.25))
                                .accessibilityLabel("内容段落")
                            Button("从此段起新建一组") { split(at: block.wrappedValue.id) }
                                .disabled(draft.wrappedValue.blocks.first?.id == block.wrappedValue.id)
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

    private var canMergeNext: Bool {
        guard let i = drafts.firstIndex(where: { $0.id == selected }), drafts.indices.contains(i + 1) else { return false }
        return drafts[i].section == drafts[i + 1].section
    }

    private func mergeNext() {
        guard canMergeNext, let i = drafts.firstIndex(where: { $0.id == selected }) else { return }
        let following = drafts.remove(at: i + 1)
        drafts[i].blocks.append(TeachingBlock(text: following.title, destination: .projection))
        drafts[i].blocks.append(contentsOf: following.blocks)
    }

    private func split(at blockID: UUID) {
        guard let i = drafts.firstIndex(where: { $0.id == selected }),
              let block = drafts[i].blocks.firstIndex(where: { $0.id == blockID }), block > 0 else { return }
        let body = Array(drafts[i].blocks[block...])
        drafts[i].blocks.removeSubrange(block...)
        let next = TeachingDraft(section: drafts[i].section, title: drafts[i].title + "（续）", blocks: body)
        drafts.insert(next, at: i + 1)
        selected = next.id
    }

    @MainActor private func refreshPreview() async {
        let input = previewInput
        guard !input.drafts.isEmpty else { preview = nil; return }
        let style = template
        error = nil
        do {
            try await Task.sleep(for: .milliseconds(210))
            let work = Task.detached(priority: .userInitiated) {
                try TeachingGenerator.layout(input.drafts, template: style)
            }
            let layout = try await withTaskCancellationHandler(operation: { try await work.value },
                                                               onCancel: { work.cancel() })
            guard !Task.isCancelled, input == previewInput else { return }
            preview = ComputedPreview(input: input, layout: layout)
        } catch is CancellationError {
            return
        } catch {
            if input == previewInput { self.error = error.localizedDescription }
        }
    }

    private func insertPreview() {
        guard let layout = currentLayout else { return }
        insert(layout.clipboard)
        dismiss()
    }
}
