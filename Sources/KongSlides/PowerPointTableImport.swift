import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

struct ImportedTable {
    let object: SlideObject
    var warnings: [String] = []

    init?(_ element: XMLElement, transform: XMLElement?, context: PowerPointLayout, unit: Double) {
        let columnNodes = element.child("tblGrid")?.children(named: "gridCol") ?? []
        let rowNodes = element.children(named: "tr")
        guard !rowNodes.isEmpty, !columnNodes.isEmpty,
              columnNodes.count <= SlideTable.maximumCells / rowNodes.count else { return nil }
        let columns = columnNodes.map { $0.number("w") ?? 0 }
        let rows = rowNodes.map { $0.number("h") ?? 0 }
        guard (rows + columns).allSatisfy({ $0 > 0 && $0 <= 200_000_000 }) else { return nil }
        let origin = transform?.child("off")
        let extent = transform?.child("ext")
        let x = (origin?.number("x") ?? 0) * unit
        let y = (origin?.number("y") ?? 0) * unit
        let width = max(1, (extent?.number("cx") ?? columns.reduce(0, +)) * unit)
        let height = max(1, (extent?.number("cy") ?? rows.reduce(0, +)) * unit)
        guard abs(x) <= 9_000, abs(y) <= 9_000, width <= 10_000, height <= 10_000 else { return nil }
        let columnEdges = SlideTable.edges(columns, across: width)
        let rowEdges = SlideTable.edges(rows, across: height)
        var cells: [SlideTable.Cell] = []
        var approximate = element.child("tblPr")?.child("tableStyleId") != nil ||
            element.child("tblPr")?.child("tableStyle") != nil

        for (row, rowNode) in rowNodes.enumerated() {
            let nodes = rowNode.children(named: "tc")
            guard nodes.count == columns.count else { return nil }
            for (column, node) in nodes.enumerated() {
                if ["1", "true"].contains(node.value("hMerge") ?? "") ||
                    ["1", "true"].contains(node.value("vMerge") ?? "") { continue }
                let rowSpan = Int(node.value("rowSpan") ?? "1") ?? 0
                let columnSpan = Int(node.value("gridSpan") ?? "1") ?? 0
                guard (1...(rows.count - row)).contains(rowSpan),
                      (1...(columns.count - column)).contains(columnSpan) else { return nil }
                let cellWidth = columnEdges[column + columnSpan] - columnEdges[column]
                let cellHeight = rowEdges[row + rowSpan] - rowEdges[row]
                let properties = node.child("tcPr")
                var cell = SlideTable.Cell(row: row, column: column, rowSpan: rowSpan, columnSpan: columnSpan)
                cell.fill = properties.flatMap { context.color($0) }
                let defaultBorder = "D2DAE6"
                let lineNames = ["lnL", "lnR", "lnT", "lnB", "lnTlToBr", "lnBlToTr"]
                approximate = approximate || lineNames.contains { name in
                    guard let line = properties?.child(name) else { return false }
                    return context.color(line)?.uppercased() != defaultBorder || line.number("w") != 7_620 ||
                        !["lnL", "lnR", "lnT", "lnB"].contains(name)
                } || ["gradFill", "blipFill", "pattFill", "cell3D"].contains { properties?.child($0) != nil } ||
                    properties?.child("solidFill").map { fill in
                        cell.fill == nil || fill.elementChildren.first?.elementChildren.isEmpty == false
                    } == true ||
                    (properties?.value("anchor").map { $0 != "t" } ?? false) ||
                    (properties?.value("vert").map { $0 != "horz" } ?? false)
                if let body = node.child("txBody") {
                    cell.text = body.text(softBreak: "\u{2028}")
                    let imported = ImportedText(body: body, shape: node, ancestry: [node], context: context,
                                                unit: unit, frame: CGRect(x: 0, y: 0, width: cellWidth, height: cellHeight))
                    cell.fontSize = imported.size ?? 18
                    cell.bold = imported.bold
                    cell.color = imported.color
                    var layout = imported.layout
                    func margin(_ name: String, defaultValue: Double, dimension: Double) -> Double {
                        min(dimension / 2, max(0, (properties?.number(name) ?? defaultValue) * unit))
                    }
                    layout.insets = .init(left: margin("marL", defaultValue: 91_440, dimension: cellWidth),
                                         top: margin("marT", defaultValue: 45_720, dimension: cellHeight),
                                         right: margin("marR", defaultValue: 91_440, dimension: cellWidth),
                                         bottom: margin("marB", defaultValue: 45_720, dimension: cellHeight))
                    cell.layout = layout
                    if let first = imported.runs.first,
                       first.baseline != 0 || imported.runs.contains(where: { !$0.matchesStyle(first) }) {
                        cell.runs = imported.runs
                    }
                    approximate = approximate || imported.mixed || imported.approximateParagraph
                }
                cells.append(cell)
            }
        }
        let table = SlideTable(columns: columns, rows: rows, cells: cells)
        guard table.isValid else { return nil }
        object = SlideObject(kind: .table, x: x, y: y, width: width, height: height, table: table)
        if approximate { warnings.append("的主题样式、特殊边框或局部排版已简化。") }
    }
}
