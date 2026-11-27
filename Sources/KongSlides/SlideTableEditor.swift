import SwiftUI

struct SlideTableEditor: View {
    @State var table: SlideTable
    let apply: (SlideTable) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: String?
    private var cell: SlideTable.Cell? { table.cells.first { $0.id == selected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("编辑表格").font(.headline)
                Spacer()
                Menu("行列") {
                    Button("在末尾添加行") { table.appendTrack(.row) }
                    Button("在末尾添加列") { table.appendTrack(.column) }
                    Divider()
                    Button("删除所选行") {
                        if let row = cell?.row { table.removeTrack(.row, at: row) }
                    }.disabled(cell == nil || table.rows.count == 1)
                    Button("删除所选列") {
                        if let column = cell?.column { table.removeTrack(.column, at: column) }
                    }.disabled(cell == nil || table.columns.count == 1)
                }
                Menu("单元格") {
                    Button("与右侧合并") { if let selected { table.mergeCell(selected, along: .column) } }
                    Button("与下方合并") { if let selected { table.mergeCell(selected, along: .row) } }
                    Button("拆分合并单元格") { if let selected { table.splitCell(selected) } }
                }.disabled(cell == nil)
            }
            HStack(spacing: 12) {
                List(selection: $selected) {
                    ForEach(table.cells) { cell in
                        Text(cellTitle(cell)).tag(cell.id)
                    }
                }
                .frame(width: 180)
                if let cell {
                    VStack(alignment: .leading) {
                        Text(cellTitle(cell)).font(.callout)
                        TextField("列宽比例", value: columnWidth(cell.column), format: .number.precision(.fractionLength(0...2)))
                        TextEditor(text: textBinding(cell.id))
                            .accessibilityLabel("单元格文字")
                            .border(.secondary.opacity(0.3))
                    }.id(cell.id)
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
        .onChange(of: table.cells.map(\.id)) {
            if cell == nil { selected = table.cells.first?.id }
        }
    }

    private func textBinding(_ id: String) -> Binding<String> {
        Binding(get: { table.cells.first { $0.id == id }?.text ?? "" }, set: { text in
            if let index = table.cells.firstIndex(where: { $0.id == id }) {
                table.cells[index].replaceText(with: text)
            }
        })
    }

    private func columnWidth(_ index: Int) -> Binding<Double> {
        Binding(get: {
            table.columns.indices.contains(index) ? table.columns[index] / table.columns.reduce(0, +) : 0
        }, set: { ratio in
            guard table.columns.indices.contains(index), table.columns.count > 1, (0.001...0.999).contains(ratio) else { return }
            let other = table.columns.reduce(0, +) - table.columns[index]
            let weight = other * ratio / (1 - ratio)
            table.columns[index] = min(200_000_000, weight)
        })
    }

    private func cellTitle(_ cell: SlideTable.Cell) -> String {
        "第 \(cell.row + 1) 行，第 \(cell.column + 1) 列"
    }
}
