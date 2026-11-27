import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

struct PowerPointGroup {
    var scaleX = 1.0
    var scaleY = 1.0
    var offsetX = 0.0
    var offsetY = 0.0

    var textScale: Double { min(scaleX, scaleY) }

    func frame(x: Double, y: Double, width: Double, height: Double, unit: Double) -> CGRect? {
        let left = (offsetX + scaleX * x) * unit
        let top = (offsetY + scaleY * y) * unit
        let resizedWidth = scaleX * width * unit
        let resizedHeight = scaleY * height * unit
        guard abs(left) <= 9_000, abs(top) <= 9_000,
              resizedWidth > 0, resizedWidth <= 10_000, resizedHeight > 0, resizedHeight <= 10_000 else { return nil }
        return CGRect(x: left, y: top, width: max(1, resizedWidth), height: max(1, resizedHeight))
    }

    private func composed(with transform: XMLElement) -> Self? {
        guard let x = transform.child("off")?.number("x"),
              let y = transform.child("off")?.number("y"),
              let width = transform.child("ext")?.number("cx"),
              let height = transform.child("ext")?.number("cy"),
              let childX = transform.child("chOff")?.number("x"),
              let childY = transform.child("chOff")?.number("y"),
              let childWidth = transform.child("chExt")?.number("cx"),
              let childHeight = transform.child("chExt")?.number("cy"),
              min(width, height, childWidth, childHeight) > 0 else { return nil }
        // Map the child coordinate rectangle to the group rectangle in the parent.
        let sx = scaleX * (width / childWidth)
        let sy = scaleY * (height / childHeight)
        let tx = offsetX + scaleX * x - sx * childX
        let ty = offsetY + scaleY * y - sy * childY
        guard (1e-10...1e10).contains(sx), (1e-10...1e10).contains(sy), tx.isFinite, ty.isFinite else { return nil }
        return Self(scaleX: sx, scaleY: sy, offsetX: tx, offsetY: ty)
    }

    static func objects(in tree: XMLElement, report: (ImportDiagnostic.Kind, String) -> Void) throws
        -> [(element: XMLElement, coordinates: Self)] {
        var result: [(XMLElement, Self)] = []
        func visit(_ tree: XMLElement, coordinates: Self, depth: Int) throws {
            for child in tree.elementChildren {
                try Task.checkCancellation()
                switch child.localName {
                case "nvGrpSpPr", "grpSpPr":
                    continue
                case "grpSp":
                    let label = child.powerPointLabel
                    guard depth < 32 else {
                        report(.unsupported, "组合「\(label)」嵌套层级过深，剩余对象未转换。")
                        continue
                    }
                    guard let transform = child.child("grpSpPr")?.child("xfrm"),
                          let next = coordinates.composed(with: transform) else {
                        report(.geometry, "组合「\(label)」的定位信息不完整，子对象按原有局部坐标导入。")
                        try visit(child, coordinates: coordinates, depth: depth + 1)
                        continue
                    }
                    if transform.hasPowerPointReorientation {
                        report(.geometry, "组合「\(label)」的整体旋转或翻转未保留。")
                    }
                    let horizontal = next.scaleX / coordinates.scaleX
                    let vertical = next.scaleY / coordinates.scaleY
                    if abs(horizontal - vertical) > max(horizontal, vertical) * 0.001 {
                        report(.text, "组合「\(label)」横纵缩放不一致，文字按较小比例等比缩放。")
                    }
                    try visit(child, coordinates: next, depth: depth + 1)
                default:
                    result.append((child, coordinates))
                }
            }
        }
        try visit(tree, coordinates: Self(), depth: 0)
        return result
    }
}

extension XMLElement {
    var powerPointLabel: String {
        let name = elementChildren.first { $0.localName?.hasPrefix("nv") == true }?.child("cNvPr")?.value("name")
        return String((name.flatMap { $0.isEmpty ? nil : $0 } ?? localName ?? "对象").prefix(60))
    }

    func powerPointFlag(_ name: String) -> Bool {
        ["1", "true"].contains(value(name) ?? "")
    }

    var hasPowerPointReorientation: Bool {
        (number("rot") ?? 0).truncatingRemainder(dividingBy: 21_600_000) != 0 ||
            powerPointFlag("flipH") || powerPointFlag("flipV")
    }
}
