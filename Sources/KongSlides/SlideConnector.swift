import Foundation

struct SlideConnector: Codable, Equatable {
    enum Arrow: String, Codable, CaseIterable {
        case none, triangle, arrow, stealth, diamond, oval

        var title: String {
            switch self {
            case .none: "无"
            case .triangle: "实心三角"
            case .arrow: "开放箭头"
            case .stealth: "燕尾箭头"
            case .diamond: "菱形"
            case .oval: "圆形"
            }
        }
    }

    enum Dash: String, Codable, CaseIterable {
        case solid, dash, dot, dashDot, lgDash, lgDashDot, lgDashDotDot, sysDash, sysDot, sysDashDot, sysDashDotDot

        var title: String {
            switch self {
            case .solid: "实线"
            case .dash, .sysDash: "虚线"
            case .dot, .sysDot: "点线"
            case .dashDot, .sysDashDot: "点划线"
            case .lgDash: "长虚线"
            case .lgDashDot: "长点划线"
            case .lgDashDotDot, .sysDashDotDot: "双点划线"
            }
        }

        var pattern: [CGFloat] {
            switch self {
            case .solid: []
            case .dash: [4, 3]
            case .dot: [1, 3]
            case .dashDot: [4, 3, 1, 3]
            case .lgDash: [8, 3]
            case .lgDashDot: [8, 3, 1, 3]
            case .lgDashDotDot: [8, 3, 1, 3, 1, 3]
            case .sysDash: [3, 1]
            case .sysDot: [1, 1]
            case .sysDashDot: [3, 1, 1, 1]
            case .sysDashDotDot: [3, 1, 1, 1, 1, 1]
            }
        }
    }

    var startX = 0.0
    var startY = 0.5
    var endX = 1.0
    var endY = 0.5
    var weight = 2.0
    var startArrow: Arrow = .none
    var endArrow: Arrow = .none
    var dash: Dash = .solid

    var isValid: Bool {
        (0.25...96).contains(weight) &&
            [startX, startY, endX, endY].allSatisfy { (0...1).contains($0) } &&
            (startX != endX || startY != endY)
    }

    func endpoints(in rect: CGRect) -> (start: CGPoint, end: CGPoint) {
        (CGPoint(x: rect.minX + startX * rect.width, y: rect.minY + startY * rect.height),
         CGPoint(x: rect.minX + endX * rect.width, y: rect.minY + endY * rect.height))
    }

    static func object(from start: CGPoint, to end: CGPoint, style: Self = .init(), color: String = Palette.ink) -> SlideObject? {
        guard [start.x, start.y, end.x, end.y].allSatisfy({ abs($0) <= 9_000 }), start != end else { return nil }
        let width = max(16, abs(end.x - start.x))
        let height = max(16, abs(end.y - start.y))
        guard width <= 10_000, height <= 10_000 else { return nil }
        let x = (start.x + end.x - width) / 2
        let y = (start.y + end.y - height) / 2
        var line = style
        func ratio(_ coordinate: CGFloat, offset: CGFloat, extent: CGFloat) -> Double {
            Double(min(1, max(0, (coordinate - offset) / extent)))
        }
        line.startX = ratio(start.x, offset: x, extent: width)
        line.startY = ratio(start.y, offset: y, extent: height)
        line.endX = ratio(end.x, offset: x, extent: width)
        line.endY = ratio(end.y, offset: y, extent: height)
        guard line.isValid else { return nil }
        return SlideObject(kind: .connector, x: x, y: y, width: width, height: height,
                           color: color, connector: line)
    }
}
