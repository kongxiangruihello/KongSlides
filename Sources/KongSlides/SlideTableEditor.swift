import SwiftUI

struct SlideTableEditor: View {
    @State var table: SlideTable
    let apply: (SlideTable) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("编辑表格单元格").font(.headline)
            HStack(spacing: 12) {
                List(selection: $selected) {
                    ForEach(table.cells) { cell in
                        Text(cellTitle(cell)).tag(cell.id)
                    }
                }
                .frame(width: 180)
                if let index = table.cells.firstIndex(where: { $0.id == selected }) {
                    VStack(alignment: .leading) {
                        Text(cellTitle(table.cells[index])).font(.callout)
                        TextEditor(text: Binding(get: { table.cells[index].text },
                                                 set: { table.cells[index].replaceText(with: $0) }))
                            .accessibilityLabel("单元格文字")
                            .border(.secondary.opacity(0.3))
                    }
                }
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("应用") { apply(table); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 540, height: 310)
        .onAppear { selected = table.cells.first?.id }
    }

    private func cellTitle(_ cell: SlideTable.Cell) -> String {
        "第 \(cell.row + 1) 行，第 \(cell.column + 1) 列"
    }
}
