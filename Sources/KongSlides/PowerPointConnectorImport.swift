import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

struct ImportedConnector {
    let object: SlideObject
    let warnings: [String]

    init?(_ element: XMLElement, context: PowerPointLayout, unit: Double, coordinates: PowerPointGroup) {
        guard let properties = element.child("spPr"),
              let transform = properties.child("xfrm"),
              let x = transform.child("off")?.number("x"), let y = transform.child("off")?.number("y"),
              let width = transform.child("ext")?.number("cx"), let height = transform.child("ext")?.number("cy"),
              width >= 0, height >= 0, width > 0 || height > 0,
              ["line", "lineInv", "straightConnector1"].contains(properties.child("prstGeom")?.value("prst") ?? "straightConnector1"),
              properties.child("custGeom") == nil,
              properties.child("ln")?.child("noFill") == nil else { return nil }

        let extentX = width / 2
        let extentY = height / 2
        let angle = (transform.number("rot") ?? 0).truncatingRemainder(dividingBy: 21_600_000) * .pi / 10_800_000
        let horizontal = transform.powerPointFlag("flipH") ? -extentX : extentX
        let vertical = (transform.powerPointFlag("flipV") != (properties.child("prstGeom")?.value("prst") == "lineInv"))
            ? -extentY : extentY
        let dx = horizontal * cos(angle) - vertical * sin(angle)
        let dy = horizontal * sin(angle) + vertical * cos(angle)
        let start = coordinates.point(x: x + extentX - dx, y: y + extentY - dy, unit: unit)
        let end = coordinates.point(x: x + extentX + dx, y: y + extentY + dy, unit: unit)

        let line = properties.child("ln")
        let reference = element.child("style")?.child("lnRef")
        let themeLines = context.theme?.child("themeElements")?.child("fmtScheme")?.child("lnStyleLst")?.children(named: "ln") ?? []
        let referenceIndex = reference?.value("idx").flatMap(Int.init) ?? 0
        let themeLine = referenceIndex > 0 && referenceIndex <= themeLines.count ? themeLines[referenceIndex - 1] : nil
        let color = line.flatMap { context.color($0) } ?? reference?.child("srgbClr")?.value("val") ??
            context.schemeColor(reference?.child("schemeClr")) ?? Palette.ink
        let weight = (line?.number("w") ?? themeLine?.number("w") ?? 25_400) * unit * coordinates.textScale
        func arrow(_ name: String) -> SlideConnector.Arrow {
            let value = line?.child(name)?.value("type") ?? themeLine?.child(name)?.value("type") ?? "none"
            return SlideConnector.Arrow(rawValue: value) ?? .none
        }
        let dash = line?.child("prstDash")?.value("val") ?? themeLine?.child("prstDash")?.value("val") ?? "solid"
        let style = SlideConnector(weight: min(96, max(0.25, weight)), startArrow: arrow("headEnd"),
                                   endArrow: arrow("tailEnd"), dash: SlideConnector.Dash(rawValue: dash) ?? .solid)
        guard let object = SlideConnector.object(from: start, to: end, style: style, color: color) else { return nil }
        self.object = object

        var warnings: [String] = []
        let links = element.child("nvCxnSpPr")?.child("cNvCxnSpPr")
        if links?.child("stCxn") != nil || links?.child("endCxn") != nil {
            warnings.append("保留了导入时的端点位置，移动相连形状时端点需手动调整。")
        }
        let customDecoration = ["headEnd", "tailEnd"].contains { name in
            guard let tip = line?.child(name) else { return false }
            return tip.value("type") != "none" && (["w", "len"].contains { tip.value($0).map { $0 != "med" } == true })
        }
        if customDecoration || ["custDash", "gradFill", "pattFill"].contains(where: { line?.child($0) != nil }) ||
            line?.child("solidFill")?.elementChildren.first?.elementChildren.isEmpty == false ||
            line?.value("cmpd").map({ $0 != "sng" }) == true {
            warnings.append("的自定义箭头尺寸、复合线条或特殊填充已简化。")
        }
        self.warnings = warnings
    }
}
