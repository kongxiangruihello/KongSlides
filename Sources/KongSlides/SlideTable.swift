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

extension SlideTable {
    enum Axis { case row, column }

    mutating func appendTrack(_ axis: Axis) {
        guard occupancy?.count ?? 0 > 0 else { return }
        switch axis {
        case .row:
            guard rows.count < Self.maximumCells / columns.count else { return }
            cells += columns.indices.map { Cell(row: rows.count, column: $0) }
            rows.append(rows.last ?? 1)
        case .column:
            guard columns.count < Self.maximumCells / rows.count else { return }
            cells += rows.indices.map { Cell(row: $0, column: columns.count) }
            columns.append(columns.last ?? 1)
        }
        sortCells()
    }

    mutating func removeTrack(_ axis: Axis, at index: Int) {
        let coordinate: WritableKeyPath<Cell, Int> = axis == .row ? \.row : \.column
        let span: WritableKeyPath<Cell, Int> = axis == .row ? \.rowSpan : \.columnSpan
        let tracks: WritableKeyPath<SlideTable, [Double]> = axis == .row ? \.rows : \.columns
        guard self[keyPath: tracks].indices.contains(index), self[keyPath: tracks].count > 1 else { return }
        self[keyPath: tracks].remove(at: index)
        cells = cells.compactMap { cell in
            var updated = cell
            let start = cell[keyPath: coordinate]
            let length = cell[keyPath: span]
            if start > index { updated[keyPath: coordinate] -= 1 }
            if start <= index && index < start + length {
                guard length > 1 else { return nil }
                updated[keyPath: span] -= 1
            }
            return updated
        }
        sortCells()
    }

    mutating func mergeCell(_ id: String, along axis: Axis) {
        guard let index = cells.firstIndex(where: { $0.id == id }) else { return }
        let cell = cells[index]
        let neighbor = cells.firstIndex {
            switch axis {
            case .row:
                return $0.row == cell.row + cell.rowSpan && $0.column == cell.column && $0.columnSpan == cell.columnSpan
            case .column:
                return $0.column == cell.column + cell.columnSpan && $0.row == cell.row && $0.rowSpan == cell.rowSpan
            }
        }
        guard let neighbor else { return }
        let next = cells[neighbor]
        switch axis {
        case .row: cells[index].rowSpan += next.rowSpan
        case .column: cells[index].columnSpan += next.columnSpan
        }
        if !next.text.isEmpty {
            let combined = [cell.text, next.text].filter { !$0.isEmpty }.joined(separator: "\n")
            cells[index].replaceText(with: combined)
        }
        cells.remove(at: neighbor)
    }

    mutating func splitCell(_ id: String) {
        guard let index = cells.firstIndex(where: { $0.id == id }) else { return }
        let cell = cells[index]
        for row in cell.row..<(cell.row + cell.rowSpan) {
            for column in cell.column..<(cell.column + cell.columnSpan) where row != cell.row || column != cell.column {
                cells.append(Cell(row: row, column: column, fill: cell.fill))
            }
        }
        cells[index].rowSpan = 1
        cells[index].columnSpan = 1
        sortCells()
    }

    private mutating func sortCells() {
        cells.sort { ($0.row, $0.column) < ($1.row, $1.column) }
    }
}
