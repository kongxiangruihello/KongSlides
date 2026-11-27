import SwiftUI

struct SlideCitationView: View {
    @State var citation: SlideCitation
    let apply: (SlideCitation) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("学术引文与出处").font(.headline)
            TextField("书名、作者或版本", text: $citation.source)
            TextField("卷次、章号或页码", text: $citation.location)
            Text("原文")
            TextEditor(text: $citation.quotation).frame(height: 85).border(.secondary.opacity(0.3))
            Text("注释")
            TextEditor(text: $citation.commentary).frame(height: 85).border(.secondary.opacity(0.3))
            Text("出处显示在投影页脚，教师讲稿和学生配布也包含引文信息。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("应用") { apply(citation); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(18).frame(width: 490)
    }
}
