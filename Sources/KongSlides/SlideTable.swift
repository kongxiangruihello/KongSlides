import Foundation

struct SlideTable: Codable, Equatable {
    struct Cell: Codable, Equatable, Identifiable {
        var row: Int
        var column: Int
        var rowSpan = 1
        var columnSpan = 1
        var text = ""
        var fontSize = 18.0
        var bold = false
        var color = Palette.ink
        var fill: String?
        var layout: SlideTextLayout?
        var runs: [SlideTextRun]?

        var id: String { "\(row):\(column)" }

        var textObject: SlideObject {
            SlideObject(text: text, fontSize: fontSize, bold: bold, color: color,
                        textLayout: layout, textRuns: runs)
        }

        mutating func replaceText(with value: String) {
            var object = textObject
            object.replaceText(with: value)
            text = object.text
            layout = object.textLayout
            runs = object.textRuns
        }
    }

    var columns: [Double]
    var rows: [Double]
    var cells: [Cell]

    static let maximumCells = 2_500

    var occupancy: [Int]? {
        guard !rows.isEmpty, rows.count <= Self.maximumCells,
              !columns.isEmpty, columns.count <= Self.maximumCells / rows.count,
              (rows + columns).allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 200_000_000 }),
              cells.count <= rows.count * columns.count else { return nil }
        var owners = Array(repeating: -1, count: rows.count * columns.count)
        for (index, cell) in cells.enumerated() {
            guard rows.indices.contains(cell.row), columns.indices.contains(cell.column),
                  (1...(rows.count - cell.row)).contains(cell.rowSpan),
                  (1...(columns.count - cell.column)).contains(cell.columnSpan) else { return nil }
            for row in cell.row..<(cell.row + cell.rowSpan) {
                for column in cell.column..<(cell.column + cell.columnSpan) {
                    let slot = row * columns.count + column
                    guard owners[slot] == -1 else { return nil }
                    owners[slot] = index
                }
            }
        }
        return owners.contains(-1) ? nil : owners
    }

    var isValid: Bool {
        occupancy != nil && cells.allSatisfy {
            (8...200).contains($0.fontSize) && $0.layout?.isValid != false && $0.textObject.validTextRuns
        }
    }

    static func edges(_ tracks: [Double], across length: Double) -> [Double] {
        let scale = length / tracks.reduce(0, +)
        return tracks.reduce(into: [0.0]) { edges, track in
            edges.append((edges.last ?? 0) + track * scale)
        }
    }
}
