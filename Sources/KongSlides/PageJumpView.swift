import SwiftUI

struct PageJumpView: View {
    let currentPage: Int
    let pageCount: Int
    let jump: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var input = ""

    private var destination: Int? { SlidePageNumber.parse(input, pageCount: pageCount) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("前往幻灯片").font(.headline)
            Text("当前第 \(currentPage) 页，共 \(pageCount) 页")
                .font(.callout).foregroundStyle(.secondary)
            TextField("输入页码", text: $input)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(openPage)
            if !input.isEmpty && destination == nil {
                Text("请输入 1 至 \(pageCount) 之间的页码。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("前往", action: openPage).keyboardShortcut(.defaultAction)
                    .disabled(destination == nil)
            }
        }
        .padding(20)
        .frame(width: 330)
        .defaultFocus($focused, true)
    }

    private func openPage() {
        guard let destination else { return }
        jump(destination)
        dismiss()
    }
}
