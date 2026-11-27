import SwiftUI

struct TeachingTemplateView: View {
    @ObservedObject var library: TeachingTemplateStore
    let insert: (TeachingTemplate) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?
    @State private var pendingDelete: TeachingTemplate?
    @State private var error: String?

    private var chosen: TeachingTemplate? {
        (TeachingTemplate.builtIns + library.items).first { $0.id == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("教学版式").font(.title2.weight(.semibold))
            HStack(spacing: 14) {
                List(selection: $selection) {
                    Section("内置") {
                        ForEach(TeachingTemplate.builtIns) { item in Text(item.name).tag(item.id) }
                    }
                    Section("我的版式") {
                        if library.items.isEmpty { Text("可从现有幻灯片保存版式").foregroundStyle(.secondary) }
                        ForEach(library.items) { item in Text(item.name).tag(item.id) }
                    }
                }
                .frame(width: 190)
                if let chosen {
                    SlideSurface(slide: chosen.slide, images: chosen.images, canvas: chosen.canvas ?? .widescreen).border(.secondary.opacity(0.2))
                }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("删除所选版式…", role: .destructive) {
                    pendingDelete = chosen
                }.disabled(!library.items.contains { $0.id == selection })
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("插入幻灯片") {
                    if let chosen { insert(chosen); dismiss() }
                }.disabled(chosen == nil).keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(minWidth: 700, minHeight: 450)
        .onAppear { selection = TeachingTemplate.builtIns.first?.id }
        .confirmationDialog("删除此版式？", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("删除", role: .destructive) {
                guard let item = pendingDelete else { return }
                do {
                    try library.remove([item.id])
                    selection = TeachingTemplate.builtIns.first?.id
                } catch { self.error = error.localizedDescription }
                pendingDelete = nil
            }
        }
    }
}
